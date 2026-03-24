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
ROBOT_NAME = os.getenv("ROBOT_NAME", "SIMBOT")
ROBOT_HOST = os.getenv("ROBOT_HOST", "robot_simulator")
ROBOT_PORT = int(os.getenv("ROBOT_PORT", "9090"))
REDIS_HOST = os.getenv("REDIS_HOST", "redis")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
HEARTBEAT_TTL = int(os.getenv("HEARTBEAT_TTL", "10"))  # seconds before considered OFFLINE
ODOM_STALE_TIMEOUT = float(os.getenv("ODOM_STALE_TIMEOUT", "5"))  # odom silence => OFFLINE
REDIS_RETRY_DELAY = float(os.getenv("REDIS_RETRY_DELAY", "2"))

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
last_odom_at = 0.0
_redis_client: redis_async.Redis | None = None


def _safe_float(value, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


async def get_redis_client(force_reconnect: bool = False) -> redis_async.Redis:
    """Return a live Redis client, recreating it when needed."""
    global _redis_client
    if force_reconnect and _redis_client is not None:
        try:
            await _redis_client.aclose()
        except Exception:
            pass
        _redis_client = None

    if _redis_client is None:
        _redis_client = redis_async.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)

    try:
        await _redis_client.ping()
    except Exception:
        if _redis_client is not None:
            try:
                await _redis_client.aclose()
            except Exception:
                pass
        _redis_client = redis_async.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)
        await _redis_client.ping()
    return _redis_client


async def wait_for_redis() -> None:
    while True:
        try:
            await get_redis_client(force_reconnect=True)
            log.info("Redis connected!")
            return
        except Exception as exc:
            log.warning(f"Waiting for Redis... ({exc})")
            await asyncio.sleep(REDIS_RETRY_DELAY)


async def push_to_redis() -> None:
    """Write robot state to Redis with retry and graceful offline fallback."""
    key_state = f"robot:{ROBOT_NAME}:state"
    key_heartbeat = f"robot:{ROBOT_NAME}:heartbeat"
    key_status = f"robot:{ROBOT_NAME}:connection_status"

    state_json = json.dumps(robot_state)
    ts = str(time.time())
    should_heartbeat = robot_state.get("connectionStatus") == "ONLINE"

    for attempt in range(2):
        try:
            r = await get_redis_client(force_reconnect=(attempt > 0))
            pipe = r.pipeline()
            pipe.set(key_state, state_json, ex=HEARTBEAT_TTL * 2)
            if should_heartbeat:
                pipe.set(key_heartbeat, ts, ex=HEARTBEAT_TTL)
            else:
                # Keep state visible but remove heartbeat so fleet_gateway marks OFFLINE.
                pipe.delete(key_heartbeat)
            pipe.set(key_status, robot_state["connectionStatus"], ex=HEARTBEAT_TTL * 2)
            pipe.publish(f"robot:{ROBOT_NAME}", state_json)
            await pipe.execute()
            return
        except Exception as exc:
            log.error(f"Redis publish failed (attempt {attempt + 1}/2): {exc}")
            await asyncio.sleep(REDIS_RETRY_DELAY)


async def _receive_topics(ws):
    """Read telemetry topics from rosbridge and push state to Redis."""
    global last_odom_at
    async for raw in ws:
        try:
            msg = json.loads(raw)
        except (TypeError, json.JSONDecodeError):
            log.warning("Ignoring malformed ROS bridge message payload")
            continue

        topic = msg.get("topic")
        data = msg.get("msg", {})
        if not isinstance(data, dict):
            data = {}

        if topic == "/odom_qr":
            pos = data.get("pose", {}).get("pose", {}).get("position", {})
            twist = data.get("twist", {}).get("twist", {}).get("linear", {})
            robot_state["mobileBaseState"]["x"] = round(_safe_float(pos.get("x")), 4)
            robot_state["mobileBaseState"]["y"] = round(_safe_float(pos.get("y")), 4)
            robot_state["mobileBaseState"]["theta"] = round(_safe_float(pos.get("z")), 4)
            speed = (_safe_float(twist.get("x")) ** 2 + _safe_float(twist.get("y")) ** 2) ** 0.5
            robot_state["mobileBaseState"]["speed"] = round(speed, 4)
            robot_state["connectionStatus"] = "ONLINE"
            last_odom_at = time.time()

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
            if isinstance(names, list) and isinstance(positions, list):
                joint_map = dict(zip(names, positions))
            else:
                joint_map = {}
            if joint_map:
                robot_state["piggybackState"] = {
                    "lift": _safe_float(joint_map.get("lift", 0.0)),
                    "turntable": _safe_float(joint_map.get("turntable", 0.0)),
                    "slide": _safe_float(joint_map.get("slide", 0.0)),
                    "hook_left": _safe_float(joint_map.get("hook_left", 0.0)),
                    "hook_right": _safe_float(joint_map.get("hook_right", 0.0)),
                }
            else:
                robot_state["piggybackState"] = False

        await push_to_redis()


async def _command_relay(ws):
    """Subscribe to Redis command channel and forward travel/control orders to rosbridge."""
    channel = f"robot:{ROBOT_NAME}:command"
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

    while True:
        pubsub = None
        try:
            r = await get_redis_client()
            pubsub = r.pubsub()
            await pubsub.subscribe(channel)
            log.info(f"Subscribed to Redis channel {channel}")

            async for message in pubsub.listen():
                if message.get("type") != "message":
                    continue

                raw_data = message.get("data")
                if isinstance(raw_data, bytes):
                    raw_data = raw_data.decode("utf-8", errors="ignore")
                if not isinstance(raw_data, str):
                    log.warning("Ignoring non-string command payload from Redis")
                    continue

                try:
                    cmd = json.loads(raw_data)
                except json.JSONDecodeError:
                    log.warning(f"Ignoring malformed JSON command payload: {raw_data!r}")
                    continue

                if not isinstance(cmd, dict):
                    log.warning("Ignoring command payload that is not a JSON object")
                    continue

                op = cmd.get("op")
                if op == "travel":
                    msg_payload = cmd.get("msg", {})
                    if not isinstance(msg_payload, dict):
                        msg_payload = {}
                    target_alias = str(msg_payload.get("target_alias") or "")
                    target_x = _safe_float(msg_payload.get("target_x"), 0.0)
                    target_y = _safe_float(msg_payload.get("target_y"), 0.0)
                    last_travel_target = {"alias": target_alias, "x": target_x, "y": target_y}
                    await publish_travel(target_alias, target_x, target_y)
                    continue

                if op == "control":
                    msg_payload = cmd.get("msg", {})
                    if not isinstance(msg_payload, dict):
                        msg_payload = {}
                    action = str(msg_payload.get("command", cmd.get("command", ""))).upper().strip()
                    if not action:
                        log.warning("Ignoring control payload without a command field")
                        continue

                    # The simulator only consumes /travel_command; to stop motion we publish
                    # a "travel to current pose" command so it immediately snaps to IDLE.
                    if action in {"PAUSE", "ESTOP", "CANCEL"}:
                        current = robot_state.get("mobileBaseState", {})
                        stop_alias = current.get("qr_id") or action
                        stop_x = _safe_float(current.get("x", 0.0))
                        stop_y = _safe_float(current.get("y", 0.0))
                        await publish_travel(str(stop_alias), stop_x, stop_y)
                        log.info(f"Applied control command {action} by freezing at ({stop_x}, {stop_y})")
                        continue

                    if action == "RESUME":
                        if last_travel_target is None:
                            log.warning("RESUME received but no prior travel target is available")
                            continue
                        await publish_travel(
                            str(last_travel_target.get("alias", "")),
                            _safe_float(last_travel_target.get("x", 0.0)),
                            _safe_float(last_travel_target.get("y", 0.0)),
                        )
                        log.info("Applied RESUME by re-sending previous travel target")
                        continue

                    log.warning(f"Ignoring unknown control command: {action}")
                    continue

                log.warning(f"Ignoring unsupported command op: {op!r}")
        except Exception as exc:
            log.error(f"Command relay Redis error: {exc}. Reconnecting in {REDIS_RETRY_DELAY}s...")
            await get_redis_client(force_reconnect=True)
            await asyncio.sleep(REDIS_RETRY_DELAY)
        finally:
            if pubsub is not None:
                try:
                    await pubsub.unsubscribe(channel)
                except Exception:
                    pass
                try:
                    await pubsub.aclose()
                except Exception:
                    pass


async def subscribe_to_rosbridge():
    """Connect to rosbridge, subscribe to topics, and relay Redis commands."""
    import websockets

    while True:
        try:
            log.info(f"Connecting to rosbridge at {ROSBRIDGE_URI}...")
            async with websockets.connect(ROSBRIDGE_URI, ping_interval=10, ping_timeout=5) as ws:
                log.info("Connected to rosbridge!")

                # Unsubscribe from /piggyback_state before (re-)subscribing.
                # rosbridge retains stale subscriptions across reconnects when
                # the client ID is reused. If we connect without unsubscribing
                # first, rosbridge may deliver duplicate messages or stale types.
                await ws.send(json.dumps({
                    "op": "unsubscribe",
                    "topic": "/piggyback_state",
                }))
                log.info("Unsubscribed from /piggyback_state (clearing stale subscription)")
                await asyncio.sleep(0.1)

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

                await asyncio.gather(
                    _receive_topics(ws),
                    _command_relay(ws),
                )
        except Exception as exc:
            log.warning(f"rosbridge connection error: {exc}. Retrying in 3s...")
            robot_state["connectionStatus"] = "OFFLINE"
            await push_to_redis()
            await asyncio.sleep(3)


async def heartbeat_loop():
    """Keep heartbeat/status updated and degrade to OFFLINE when odometry goes stale."""
    global last_odom_at
    while True:
        now = time.time()
        if last_odom_at > 0 and (now - last_odom_at) > ODOM_STALE_TIMEOUT:
            if robot_state["connectionStatus"] != "OFFLINE":
                # If odometry stops mid-route, remove heartbeat so fleet_gateway
                # switches the robot to OFFLINE immediately.
                log.warning("Odometry stale; marking robot OFFLINE")
            robot_state["connectionStatus"] = "OFFLINE"
            robot_state["lastActionStatus"] = "ERROR"

        await push_to_redis()
        await asyncio.sleep(max(1, HEARTBEAT_TTL // 2))


async def main():
    log.info(f"Starting Robot Bridge for {ROBOT_NAME} ({ROSBRIDGE_URI}) -> Redis ({REDIS_HOST}:{REDIS_PORT})")
    await wait_for_redis()

    robot_state["connectionStatus"] = "ONLINE"
    await asyncio.gather(
        subscribe_to_rosbridge(),
        heartbeat_loop(),
    )


if __name__ == "__main__":
    asyncio.run(main())
