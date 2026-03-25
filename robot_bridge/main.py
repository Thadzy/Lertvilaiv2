#!/usr/bin/env python3
"""
Robot Bridge Service
====================
Connects to robot_simulator (ROS2 rosbridge WebSocket) and feeds
telemetry into Redis so fleet_gateway sees FACOBOT as ONLINE.

Redis key format (reverse-engineered from fleet_gateway behavior):
  robot:{robot_name}:state  -> JSON with robot state
  robot:{robot_name}:heartbeat -> timestamp (used to determine ONLINE/OFFLINE)

The bridge polls robot_simulator and continuously refreshes heartbeat
so fleet_gateway keeps the robot as ONLINE.
"""

import asyncio
import json
import logging
import math
import os
import time
import redis.asyncio as redis_async

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger(__name__)

# ---------- Config ----------
ROBOT_NAME = os.getenv("ROBOT_NAME", "FACOBOT")
ROBOT_HOST = os.getenv("ROBOT_HOST", "robot_simulator")
ROBOT_PORT = int(os.getenv("ROBOT_PORT", "9090"))
REDIS_HOST = os.getenv("REDIS_HOST", "redis")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
HEARTBEAT_TTL = int(os.getenv("HEARTBEAT_TTL", "10"))  # seconds before considered OFFLINE
ODOM_STALE_TIMEOUT = float(os.getenv("ODOM_STALE_TIMEOUT", "5"))  # odom silence => OFFLINE
REDIS_RETRY_DELAY = float(os.getenv("REDIS_RETRY_DELAY", "2"))

ROSBRIDGE_URI = f"ws://{ROBOT_HOST}:{ROBOT_PORT}"

# ---------- Path-execution constants ----------
# Distance (metres) within which the robot is considered to have "arrived" at a waypoint.
ARRIVAL_TOLERANCE: float = float(os.getenv("ARRIVAL_TOLERANCE", "0.15"))
# Maximum seconds to wait for the robot to reach a single waypoint before aborting.
WAYPOINT_TIMEOUT: float = float(os.getenv("WAYPOINT_TIMEOUT", "60.0"))
# Seconds between distance-check polls inside the arrival wait-loop.
POLL_INTERVAL: float = float(os.getenv("POLL_INTERVAL", "0.5"))

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


# Handle to the currently-running path-execution task so PAUSE/CANCEL can cancel it.
_active_path_task: asyncio.Task | None = None


async def _publish_travel(ws, alias: str, x: float, y: float) -> None:
    
    # Construct the internal command object
    # Including 'th' and 'method' keys as identified during manual debugging
    inner_cmd = {
        "x": round(float(x), 4),
        "y": round(float(y), 4),
        "th": 0.0,
        "method": "goto"
    }
    
    # Standard std_msgs/String structure for rosbridge
    command_data = json.dumps(inner_cmd)
    ros_payload = json.dumps({
        "op": "publish",
        "topic": "/web_command_gateway",
        "type": "std_msgs/msg/String",
        "msg": {
            "data": command_data
        }
    })
    
    log.info(f"→ ROS2 /web_command_gateway | target={alias} | payload: {command_data}")
    await ws.send(ros_payload)


async def _execute_path_waypoints(
    ws,
    waypoints: list[dict],
) -> None:
    """Execute a sequence of waypoints with closed-loop distance feedback.

    For each waypoint the function:
    1. Publishes the target to ``/travel_command``.
    2. Polls ``robot_state["mobileBaseState"]`` (continuously refreshed by
       ``_receive_topics``) until the Euclidean distance to the target falls
       within ``ARRIVAL_TOLERANCE`` metres.
    3. Moves on to the next waypoint, or aborts on timeout.

    On timeout the robot's ``lastActionStatus`` is set to ``ERROR`` and the
    function returns early, leaving it to the operator (or a higher-level
    recovery routine) to cancel/re-plan.

    Args:
        ws: Live rosbridge WebSocket connection.
        waypoints: Ordered list of ``{"alias": str, "x": float, "y": float}``
            dicts representing the full A* path to execute.
    """
    total: int = len(waypoints)
    log.info(f"[Path] Starting execution of {total} waypoint(s).")

    for idx, waypoint in enumerate(waypoints, start=1):
        alias: str = str(waypoint.get("alias") or "")
        target_x: float = _safe_float(waypoint.get("x"), 0.0)
        target_y: float = _safe_float(waypoint.get("y"), 0.0)

        # --- Publish this waypoint ---
        await _publish_travel(ws, alias, target_x, target_y)
        log.info(f"[Path] Waypoint {idx}/{total}: target=({target_x:.3f}, {target_y:.3f})")

        # --- Wait until the robot arrives (closed-loop check) ---
        deadline: float = time.time() + WAYPOINT_TIMEOUT
        while True:
            current_x: float = _safe_float(robot_state["mobileBaseState"].get("x"), 0.0)
            current_y: float = _safe_float(robot_state["mobileBaseState"].get("y"), 0.0)
            distance: float = math.hypot(current_x - target_x, current_y - target_y)

            if distance <= ARRIVAL_TOLERANCE:
                log.info(
                    f"[Path] Reached waypoint {idx}/{total} "
                    f"(dist={distance:.3f} m ≤ {ARRIVAL_TOLERANCE} m tolerance)."
                )
                break

            if time.time() > deadline:
                log.error(
                    f"[Path] TIMEOUT waiting for waypoint {idx}/{total} "
                    f"alias={alias!r} target=({target_x:.3f}, {target_y:.3f}) — "
                    f"current=({current_x:.3f}, {current_y:.3f}) dist={distance:.3f} m "
                    f"after {WAYPOINT_TIMEOUT}s. Aborting path."
                )
                robot_state["lastActionStatus"] = "ERROR"
                await push_to_redis()
                return  # Abort: leave recovery to operator / higher-level planner

            await asyncio.sleep(POLL_INTERVAL)

    # All waypoints reached successfully
    log.info("[Path] All waypoints reached. Path execution complete.")
    robot_state["lastActionStatus"] = "IDLE"
    await push_to_redis()


async def _command_relay(ws):
    """Subscribe to Redis command channel and forward travel/control orders to rosbridge.

    This coroutine runs for the lifetime of a single WebSocket connection.  Any
    WebSocket-level error (send failure, connection closed) is intentionally
    re-raised so that ``asyncio.gather`` in ``subscribe_to_rosbridge`` can cancel
    ``_receive_topics`` and trigger a clean reconnect.  Only one Redis pubsub
    subscription is ever active at a time, preventing duplicate command delivery.
    """
    global _active_path_task

    channel = f"robot:{ROBOT_NAME}:command"
    # Remember the last single-waypoint target so RESUME can re-send it.
    last_travel_target: dict | None = None

    r = await get_redis_client()
    pubsub = r.pubsub()
    try:
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

            # ── Single-waypoint travel ─────────────────────────────────────────
            if op == "travel":
                msg_payload = cmd.get("msg", {})
                if not isinstance(msg_payload, dict):
                    msg_payload = {}
                target_alias = str(msg_payload.get("target_alias") or "")
                target_x = _safe_float(msg_payload.get("target_x"), 0.0)
                target_y = _safe_float(msg_payload.get("target_y"), 0.0)
                last_travel_target = {"alias": target_alias, "x": target_x, "y": target_y}
                await _publish_travel(ws, target_alias, target_x, target_y)
                continue

            # ── Multi-waypoint path execution (closed-loop) ───────────────────
            if op == "execute_path":
                waypoints: list[dict] = cmd.get("waypoints", [])
                if not isinstance(waypoints, list) or not waypoints:
                    log.warning("execute_path received with empty or invalid waypoints list")
                    continue

                # Cancel any in-flight path before starting a new one.
                if _active_path_task and not _active_path_task.done():
                    log.info("[Path] Cancelling previous path task before starting new one.")
                    _active_path_task.cancel()
                    try:
                        await _active_path_task
                    except asyncio.CancelledError:
                        pass

                # Remember final destination for RESUME support.
                last_wp = waypoints[-1]
                last_travel_target = {
                    "alias": str(last_wp.get("alias") or ""),
                    "x": _safe_float(last_wp.get("x"), 0.0),
                    "y": _safe_float(last_wp.get("y"), 0.0),
                }

                # Run path execution in a background task so this loop remains
                # responsive to incoming PAUSE / CANCEL commands.
                _active_path_task = asyncio.create_task(
                    _execute_path_waypoints(ws, waypoints),
                    name="path_executor",
                )
                continue

            # ── Control commands (PAUSE / RESUME / ESTOP / CANCEL) ────────────
            if op == "control":
                msg_payload = cmd.get("msg", {})
                if not isinstance(msg_payload, dict):
                    msg_payload = {}
                action = str(msg_payload.get("command", cmd.get("command", ""))).upper().strip()
                if not action:
                    log.warning("Ignoring control payload without a command field")
                    continue

                if action in {"PAUSE", "ESTOP", "CANCEL"}:
                    # Stop any running path task immediately.
                    if _active_path_task and not _active_path_task.done():
                        log.info(f"[{action}] Cancelling active path task.")
                        _active_path_task.cancel()
                        try:
                            await _active_path_task
                        except asyncio.CancelledError:
                            pass
                        _active_path_task = None

                    # Freeze the robot at its current position.
                    current = robot_state.get("mobileBaseState", {})
                    stop_alias: str = str(current.get("qr_id") or action)
                    stop_x: float = _safe_float(current.get("x", 0.0))
                    stop_y: float = _safe_float(current.get("y", 0.0))
                    await _publish_travel(ws, stop_alias, stop_x, stop_y)
                    log.info(f"Applied {action}: froze robot at ({stop_x:.3f}, {stop_y:.3f})")
                    continue

                if action == "RESUME":
                    if last_travel_target is None:
                        log.warning("RESUME received but no prior travel target is available")
                        continue
                    await _publish_travel(
                        ws,
                        str(last_travel_target.get("alias", "")),
                        _safe_float(last_travel_target.get("x", 0.0)),
                        _safe_float(last_travel_target.get("y", 0.0)),
                    )
                    log.info("Applied RESUME: re-sent previous travel target")
                    continue

                log.warning(f"Ignoring unknown control command: {action!r}")
                continue

            log.warning(f"Ignoring unsupported command op: {op!r}")

    finally:
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
