#!/usr/bin/env python3
"""
Robot Bridge Service
====================
Connects to robot_simulator (ROS2 rosbridge WebSocket) and feeds
telemetry into Redis so fleet_gateway sees SIMBOT as ONLINE.

Redis key format (reverse-engineered from fleet_gateway behavior):
  robot:{robot_name}:state  -> JSON with robot state
  robot:{robot_name}:heartbeat -> timestamp (used to determine ONLINE/OFFLINE)

The bridge polls robot_simulator and continuously refreshes heartbeat
so fleet_gateway keeps the robot as ONLINE.
"""

import asyncio
import json
import logging
import os
import time
import redis.asyncio as redis_async

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger(__name__)

# ---------- Config ----------
ROBOT_NAME    = os.getenv("ROBOT_NAME", "SIMBOT")
ROBOT_HOST    = os.getenv("ROBOT_HOST", "robot_simulator")
ROBOT_PORT    = int(os.getenv("ROBOT_PORT", "9090"))
REDIS_HOST    = os.getenv("REDIS_HOST", "redis")
REDIS_PORT    = int(os.getenv("REDIS_PORT", "6379"))
HEARTBEAT_TTL = int(os.getenv("HEARTBEAT_TTL", "10"))  # seconds before considered OFFLINE

ROSBRIDGE_URI = f"ws://{ROBOT_HOST}:{ROBOT_PORT}"

# ---------- State ----------
robot_state = {
    "name": ROBOT_NAME,
    "connectionStatus": "ONLINE",
    "lastActionStatus": "IDLE",
    "mobileBaseState": {
        "x": 0.0,
        "y": 0.0,
        "theta": 0.0,
        "qr_id": None,
        "speed": 0.0,
    },
    "piggybackState": False,
    "autorun": False,
}


async def _receive_topics(r: redis_async.Redis, ws):
    """Read telemetry topics from rosbridge and push state to Redis."""
    async for raw in ws:
        msg = json.loads(raw)
        topic = msg.get("topic")
        data = msg.get("msg", {})

        if topic == "/odom_qr":
            pos = data.get("pose", {}).get("pose", {}).get("position", {})
            twist = data.get("twist", {}).get("twist", {}).get("linear", {})
            robot_state["mobileBaseState"]["x"] = round(pos.get("x", 0.0), 4)
            robot_state["mobileBaseState"]["y"] = round(pos.get("y", 0.0), 4)
            robot_state["mobileBaseState"]["theta"] = round(pos.get("z", 0.0), 4)
            speed = (twist.get("x", 0.0) ** 2 + twist.get("y", 0.0) ** 2) ** 0.5
            robot_state["mobileBaseState"]["speed"] = round(speed, 4)

            if speed > 0.01:
                robot_state["lastActionStatus"] = "RUNNING"
            else:
                robot_state["lastActionStatus"] = "IDLE"

        elif topic == "/qr_id":
            robot_state["mobileBaseState"]["qr_id"] = data.get("data")

        elif topic == "/piggyback_state":
            # sensor_msgs/JointState: names=[lift,turntable,slide,hook_left,hook_right]
            names = data.get("name", [])
            positions = data.get("position", [])
            joint_map = dict(zip(names, positions))
            if joint_map:
                robot_state["piggybackState"] = {
                    "lift":       joint_map.get("lift", 0.0),
                    "turntable":  joint_map.get("turntable", 0.0),
                    "slide":      joint_map.get("slide", 0.0),
                    "hook_left":  joint_map.get("hook_left", 0.0),
                    "hook_right": joint_map.get("hook_right", 0.0),
                }
            else:
                robot_state["piggybackState"] = False

        await push_to_redis(r)


async def _command_relay(r: redis_async.Redis, ws):
    """Subscribe to Redis command channel and forward travel/control orders to rosbridge."""
    pubsub = r.pubsub()
    channel = f"robot:{ROBOT_NAME}:command"
    await pubsub.subscribe(channel)
    log.info(f"Subscribed to Redis channel {channel}")
    last_travel_target: dict | None = None

    async def publish_travel(alias: str, x: float, y: float):
        nav_data = json.dumps({
            "alias": alias,
            "x": x,
            "y": y,
        })
        ros_payload = {
            "op": "publish",
            "topic": "/travel_command",
            "msg": {"data": nav_data},
        }
        ros_payload_str = json.dumps(ros_payload)
        log.info(f"Sending to ROS2: {ros_payload_str}")
        await ws.send(ros_payload_str)
    try:
        async for message in pubsub.listen():
            if message["type"] != "message":
                continue
            try:
                cmd = json.loads(message["data"])
                op = cmd.get("op")
                if op == "travel":
                    m = cmd.get("msg", {})
                    target_alias = m.get("target_alias", "")
                    target_x     = m.get("target_x")
                    target_y     = m.get("target_y")
                    x = target_x if target_x is not None else 0.0
                    y = target_y if target_y is not None else 0.0
                    last_travel_target = {"alias": target_alias, "x": x, "y": y}
                    await publish_travel(target_alias, x, y)
                elif op == "control":
                    m = cmd.get("msg", {})
                    action = str(m.get("command", cmd.get("command", ""))).upper().strip()

                    # The simulator only consumes /travel_command; to stop motion we publish
                    # a "travel to current pose" command so it immediately snaps to IDLE.
                    if action in {"PAUSE", "ESTOP", "CANCEL"}:
                        current = robot_state.get("mobileBaseState", {})
                        stop_alias = current.get("qr_id") or action
                        stop_x = float(current.get("x", 0.0))
                        stop_y = float(current.get("y", 0.0))
                        await publish_travel(str(stop_alias), stop_x, stop_y)
                        log.info(f"Applied control command {action} by freezing at ({stop_x}, {stop_y})")
                    elif action == "RESUME":
                        if last_travel_target is None:
                            log.warning("RESUME received but no prior travel target is available")
                            continue
                        await publish_travel(
                            str(last_travel_target.get("alias", "")),
                            float(last_travel_target.get("x", 0.0)),
                            float(last_travel_target.get("y", 0.0)),
                        )
                        log.info("Applied RESUME by re-sending previous travel target")
                    else:
                        log.warning(f"Ignoring unknown control command: {action}")
                    await ws.send(ros_payload_str)
            except Exception as e:
                log.error(f"Command relay error processing message: {e}")
    finally:
        await pubsub.unsubscribe(channel)
        await pubsub.aclose()


async def subscribe_to_rosbridge(r: redis_async.Redis):
    """Connect to rosbridge, subscribe to topics, and relay Redis commands."""
    import websockets

    while True:
        try:
            log.info(f"Connecting to rosbridge at {ROSBRIDGE_URI}...")
            async with websockets.connect(ROSBRIDGE_URI, ping_interval=10, ping_timeout=5) as ws:
                log.info("Connected to rosbridge!")

                # Unsubscribe from /piggyback_state before (re-)subscribing.
                # rosbridge retains stale subscriptions across reconnects when
                # the client ID is reused.  If we connect without unsubscribing
                # first, rosbridge may deliver duplicate messages or use the
                # wrong message type from a previous session, causing parse
                # errors in the JointState handler.  Sending an explicit
                # unsubscribe followed by a short pause clears any ghost
                # subscription on the server side before we create a fresh one.
                await ws.send(json.dumps({
                    "op": "unsubscribe",
                    "topic": "/piggyback_state",
                }))
                log.info("Unsubscribed from /piggyback_state (clearing any stale subscription)")
                await asyncio.sleep(0.1)  # Give rosbridge time to process the unsubscribe

                # Subscribe to all telemetry topics
                for topic, msg_type in [
                    ("/odom_qr", "nav_msgs/msg/Odometry"),
                    ("/qr_id", "std_msgs/msg/String"),
                    ("/piggyback_state", "sensor_msgs/msg/JointState"),
                ]:
                    await ws.send(json.dumps({
                        "op": "subscribe",
                        "topic": topic,
                        "type": msg_type,
                        "throttle_rate": 200,  # max 5Hz per topic
                    }))
                    log.info(f"Subscribed to {topic}")

                # Run telemetry receiver and command relay concurrently on this connection.
                # If either raises (e.g. ws closes), asyncio.gather cancels the other.
                await asyncio.gather(
                    _receive_topics(r, ws),
                    _command_relay(r, ws),
                )

        except Exception as e:
            log.warning(f"rosbridge connection error: {e}. Retrying in 3s...")
            robot_state["connectionStatus"] = "OFFLINE"
            await push_to_redis(r)
            await asyncio.sleep(3)


async def push_to_redis(r: redis_async.Redis):
    """Write robot state and heartbeat to Redis."""
    key_state     = f"robot:{ROBOT_NAME}:state"
    key_heartbeat = f"robot:{ROBOT_NAME}:heartbeat"
    key_status    = f"robot:{ROBOT_NAME}:connection_status"

    state_json = json.dumps(robot_state)
    ts = str(time.time())

    pipe = r.pipeline()
    pipe.set(key_state, state_json, ex=HEARTBEAT_TTL * 2)
    pipe.set(key_heartbeat, ts, ex=HEARTBEAT_TTL)
    pipe.set(key_status, robot_state["connectionStatus"], ex=HEARTBEAT_TTL * 2)
    # Also publish a channel for fleet_gateway to pick up
    pipe.publish(f"robot:{ROBOT_NAME}", state_json)
    await pipe.execute()


async def heartbeat_loop(r: redis_async.Redis):
    """Keep the heartbeat alive even when no data arrives."""
    while True:
        if robot_state["connectionStatus"] == "ONLINE":
            await push_to_redis(r)
        await asyncio.sleep(HEARTBEAT_TTL // 2)


async def main():
    log.info(f"Starting Robot Bridge for {ROBOT_NAME} ({ROSBRIDGE_URI}) -> Redis ({REDIS_HOST}:{REDIS_PORT})")
    r = redis_async.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)

    # Wait for Redis
    for i in range(30):
        try:
            await r.ping()
            log.info("Redis connected!")
            break
        except Exception as e:
            log.warning(f"Waiting for Redis... ({e})")
            await asyncio.sleep(2)

    robot_state["connectionStatus"] = "ONLINE"
    await asyncio.gather(
        subscribe_to_rosbridge(r),
        heartbeat_loop(r),
    )


if __name__ == "__main__":
    asyncio.run(main())
