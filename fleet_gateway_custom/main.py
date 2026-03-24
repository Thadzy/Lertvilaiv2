"""
Custom Fleet Gateway
====================
Replacement for the broken journeykmutt/fleet_gateway binary.

Reads robot state from Redis (written by robot_bridge) and exposes
the same Strawberry GraphQL API on port 8000.

Redis key format (written by robot_bridge/main.py):
  robot:{name}:state      -> JSON robot state
  robot:{name}:heartbeat  -> timestamp (existence = ONLINE)
"""
from __future__ import annotations

import json
import os
import asyncio
import logging
from contextlib import asynccontextmanager
from enum import Enum
from typing import AsyncGenerator, Optional
from datetime import datetime, timezone

import redis.asyncio as aioredis
import strawberry
from fastapi import FastAPI
from strawberry.fastapi import GraphQLRouter

# ── Config ────────────────────────────────────────────────────────────────────
REDIS_HOST = os.getenv("REDIS_HOST", "redis")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
ROBOTS_CONFIG: dict = json.loads(os.getenv("ROBOTS_CONFIG", "{}"))
log = logging.getLogger(__name__)

# ── Enums ─────────────────────────────────────────────────────────────────────
@strawberry.enum
class RobotConnectionStatus(Enum):
    ONLINE = "ONLINE"
    OFFLINE = "OFFLINE"


@strawberry.enum
class RobotActionStatus(Enum):
    IDLE = "IDLE"
    RUNNING = "RUNNING"
    ERROR = "ERROR"


@strawberry.enum
class JobOperation(Enum):
    PICKUP = "PICKUP"
    DELIVERY = "DELIVERY"
    TRAVEL = "TRAVEL"


@strawberry.enum
class OrderStatus(Enum):
    QUEUED = "QUEUED"
    IN_PROGRESS = "IN_PROGRESS"
    DONE = "DONE"
    CANCELLED = "CANCELLED"
    ERROR = "ERROR"


@strawberry.enum
class NodeType(Enum):
    STORAGE = "STORAGE"
    STAGING = "STAGING"
    CHARGING = "CHARGING"
    INTERSECTION = "INTERSECTION"
    OTHER = "OTHER"


# ── GraphQL Types ─────────────────────────────────────────────────────────────
@strawberry.type
class Tag:
    qr_id: str
    timestamp: Optional[datetime] = None


@strawberry.type
class Pose:
    x: float
    y: float
    a: float
    timestamp: Optional[datetime] = None


@strawberry.type
class MobileBaseState:
    tag: Optional[Tag] = None
    pose: Optional[Pose] = None


@strawberry.type
class PiggybackState:
    lift: float = 0.0
    turntable: float = 0.0
    slide: float = 0.0
    hook_left: float = 0.0
    hook_right: float = 0.0
    timestamp: Optional[datetime] = None


@strawberry.type
class RobotCell:
    height: float
    holding: Optional[str] = None  # request UUID or None


@strawberry.type
class Node:
    id: int
    alias: Optional[str] = None
    tag_id: Optional[str] = None
    x: float = 0.0
    y: float = 0.0
    height: float = 0.0
    node_type: NodeType = NodeType.OTHER


@strawberry.type
class Job:
    uuid: str
    status: OrderStatus
    operation: JobOperation
    target_node: Optional[Node] = None
    request_uuid: Optional[str] = None
    handling_robot_name: str = ""


@strawberry.type
class Request:
    uuid: str
    status: OrderStatus
    pickup_uuid: Optional[str] = None
    delivery_uuid: Optional[str] = None
    handling_robot_name: str = ""


@strawberry.type
class Robot:
    name: str
    connection_status: RobotConnectionStatus
    last_action_status: RobotActionStatus
    mobile_base_state: Optional[MobileBaseState] = None
    piggyback_state: Optional[PiggybackState] = None
    autorun: bool = False
    cells: list[RobotCell] = strawberry.field(default_factory=list)
    current_job: Optional[Job] = None
    job_queue: list[Job] = strawberry.field(default_factory=list)


@strawberry.type
class JobOrderResult:
    success: bool
    message: str
    job: Optional[Job] = None


@strawberry.type
class RequestOrderResult:
    success: bool
    message: str
    request: Optional[Request] = None


@strawberry.type
class WarehouseOrderResult:
    success: bool
    message: str
    requests: list[Request] = strawberry.field(default_factory=list)


# ── Input Types ───────────────────────────────────────────────────────────────
@strawberry.input
class PickupOrderInput:
    robot_name: str
    target_node_id: Optional[int] = None
    target_node_alias: Optional[str] = None


@strawberry.input
class DeliveryOrderInput:
    robot_name: str
    cell_level: int
    target_node_id: Optional[int] = None
    target_node_alias: Optional[str] = None


@strawberry.input
class TravelOrderInput:
    robot_name: str
    target_node_id: Optional[int] = None
    target_node_alias: Optional[str] = None
    target_x: Optional[float] = None  # Metres — forwarded to robot for navigation
    target_y: Optional[float] = None  # Metres — forwarded to robot for navigation


# ── Redis helpers ─────────────────────────────────────────────────────────────
_redis: Optional[aioredis.Redis] = None

async def get_redis(force_reconnect: bool = False) -> aioredis.Redis:
    global _redis
    if force_reconnect and _redis is not None:
        try:
            await _redis.aclose()
        except Exception:
            pass
        _redis = None
    if _redis is None:
        _redis = aioredis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)
    return _redis


async def with_redis(label: str, op, fallback=None):
    """
    Execute a Redis operation with one reconnect retry. Returns `fallback`
    instead of raising when fallback is provided.
    """
    for attempt in range(2):
        try:
            r = await get_redis(force_reconnect=(attempt > 0))
            return await op(r)
        except Exception as exc:
            log.error(f"Redis {label} failed (attempt {attempt + 1}/2): {exc}")
            await asyncio.sleep(0.2)
    if fallback is not None:
        return fallback
    raise RuntimeError(f"Redis {label} failed after retries")


def _parse_robot_state(name: str, raw: Optional[str], heartbeat: Optional[str]) -> Robot:
    """Convert Redis state JSON into a Robot GraphQL object."""
    now = datetime.now(timezone.utc)

    # Determine connection status from heartbeat key existence
    conn_status = RobotConnectionStatus("ONLINE") if heartbeat else RobotConnectionStatus("OFFLINE")

    if not raw:
        return Robot(
            name=name,
            connection_status=conn_status,
            last_action_status=RobotActionStatus("IDLE"),
        )

    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return Robot(name=name, connection_status=conn_status,
                     last_action_status=RobotActionStatus("IDLE"))
    if heartbeat:
        status_from_robot = data.get("connectionStatus", "OFFLINE")
        try:
            conn_status = RobotConnectionStatus(status_from_robot)
        except ValueError:
            conn_status = RobotConnectionStatus("OFFLINE")
    else:
        conn_status = RobotConnectionStatus("OFFLINE")
    action_raw = data.get("lastActionStatus", "IDLE")
    try:
        action_status = RobotActionStatus(action_raw)
    except ValueError:
        action_status = RobotActionStatus("IDLE")

    # Mobile base state
    mb = data.get("mobileBaseState") or {}
    tag = None
    qr_id = mb.get("qr_id")
    if qr_id:
        tag = Tag(qr_id=str(qr_id), timestamp=now)

    pose = Pose(x=mb.get("x", 0.0), y=mb.get("y", 0.0),
                a=mb.get("theta", 0.0), timestamp=now)
    mobile_base_state = MobileBaseState(tag=tag, pose=pose)

    # Piggyback state (simplified - real data may differ)
    piggyback_raw = data.get("piggybackState")
    piggyback = None
    if isinstance(piggyback_raw, dict):
        piggyback = PiggybackState(
            lift=piggyback_raw.get("lift", 0.0),
            turntable=piggyback_raw.get("turntable", 0.0),
            slide=piggyback_raw.get("slide", 0.0),
            hook_left=piggyback_raw.get("hook_left", 0.0),
            hook_right=piggyback_raw.get("hook_right", 0.0),
            timestamp=now,
        )

    autorun = bool(data.get("autorun", False))

    return Robot(
        name=name,
        connection_status=conn_status,
        last_action_status=action_status,
        mobile_base_state=mobile_base_state,
        piggyback_state=piggyback,
        autorun=autorun,
    )


async def fetch_robot(name: str) -> Robot:
    state_key = f"robot:{name}:state"
    heartbeat_key = f"robot:{name}:heartbeat"
    raw, heartbeat = await with_redis(
        f"mget:{name}",
        lambda r: r.mget(state_key, heartbeat_key),
        fallback=(None, None),
    )
    return _parse_robot_state(name, raw, heartbeat)


async def fetch_all_robots() -> list[Robot]:
    robot_names = list(ROBOTS_CONFIG.keys())
    return [await fetch_robot(name) for name in robot_names]


# ── GraphQL Schema ────────────────────────────────────────────────────────────
@strawberry.type
class Query:
    @strawberry.field(description="Get a specific robot by name.")
    async def robot(self, name: str) -> Optional[Robot]:
        if name not in ROBOTS_CONFIG:
            return None
        return await fetch_robot(name)

    @strawberry.field(description="Get all robots in the fleet.")
    async def robots(self) -> list[Robot]:
        return await fetch_all_robots()

    @strawberry.field(description="Get all warehouse jobs.")
    async def jobs(self) -> list[Job]:
        return []

    @strawberry.field(description="Get a specific job by UUID.")
    async def job(self, uuid: str) -> Optional[Job]:
        return None

    @strawberry.field(description="Get all warehouse requests.")
    async def requests(self) -> list[Request]:
        return []

    @strawberry.field(description="Get a specific request by UUID.")
    async def request(self, uuid: str) -> Optional[Request]:
        return None


@strawberry.type
class Mutation:
    @strawberry.mutation
    async def send_pickup_order(self, order: PickupOrderInput) -> JobOrderResult:
        """Dispatch a pickup order to the target robot via Redis pub/sub.

        Publishes a JSON command to ``robot:{robot_name}:command`` so that
        robot_bridge (or any subscriber) can forward it to the physical robot
        over the rosbridge WebSocket.

        Args:
            order: Pickup order input containing robot name and target node.

        Returns:
            JobOrderResult indicating success or failure.
        """
        channel = f"robot:{order.robot_name}:command"
        command = json.dumps({
            "op": "pickup",
            "topic": "/pickup_command",
            "msg": {
                "target_alias": order.target_node_alias,
                "target_node_id": order.target_node_id,
            },
        })
        try:
            await with_redis(
                f"publish:{channel}",
                lambda r: r.publish(channel, command),
            )
            return JobOrderResult(
                success=True,
                message=f"Pickup order dispatched to {order.robot_name}",
            )
        except Exception as exc:  # noqa: BLE001
            return JobOrderResult(
                success=False,
                message=f"Redis error dispatching pickup to {order.robot_name}: {exc}",
            )

    @strawberry.mutation
    async def send_delivery_order(self, order: DeliveryOrderInput) -> JobOrderResult:
        """Dispatch a delivery order to the target robot via Redis pub/sub.

        Publishes a JSON command to ``robot:{robot_name}:command`` so that
        robot_bridge (or any subscriber) can forward it to the physical robot
        over the rosbridge WebSocket.

        Args:
            order: Delivery order input containing robot name, cell level, and target node.

        Returns:
            JobOrderResult indicating success or failure.
        """
        channel = f"robot:{order.robot_name}:command"
        command = json.dumps({
            "op": "delivery",
            "topic": "/delivery_command",
            "msg": {
                "target_alias": order.target_node_alias,
                "target_node_id": order.target_node_id,
                "cell_level": order.cell_level,
            },
        })
        try:
            await with_redis(
                f"publish:{channel}",
                lambda r: r.publish(channel, command),
            )
            return JobOrderResult(
                success=True,
                message=f"Delivery order dispatched to {order.robot_name}",
            )
        except Exception as exc:  # noqa: BLE001
            return JobOrderResult(
                success=False,
                message=f"Redis error dispatching delivery to {order.robot_name}: {exc}",
            )

    @strawberry.mutation
    async def send_travel_order(self, order: TravelOrderInput) -> JobOrderResult:
        """Dispatch a travel order to the target robot via Redis pub/sub.

        Publishes a JSON command to ``robot:{robot_name}:command`` so that
        robot_bridge (or any subscriber) can forward it to the physical robot
        over the rosbridge WebSocket.

        Args:
            order: Travel order input containing robot name and target node.

        Returns:
            JobOrderResult indicating success or failure.
        """
        channel = f"robot:{order.robot_name}:command"
        command = json.dumps({
            "op": "travel",
            "topic": "/travel_command",
            "msg": {
                "target_alias": order.target_node_alias,
                "target_node_id": order.target_node_id,
                "target_x": order.target_x,
                "target_y": order.target_y,
            },
        })
        try:
            await with_redis(
                f"publish:{channel}",
                lambda r: r.publish(channel, command),
            )
            return JobOrderResult(
                success=True,
                message=f"Travel order dispatched to {order.robot_name}",
            )
        except Exception as exc:  # noqa: BLE001
            return JobOrderResult(
                success=False,
                message=f"Redis error dispatching travel to {order.robot_name}: {exc}",
            )

    @strawberry.mutation
    async def send_robot_command(self, robot_name: str, command: str) -> JobOrderResult:
        """Dispatch a control command (PAUSE/RESUME/ESTOP/CANCEL) via Redis pub/sub."""
        normalized = command.upper().strip()
        command_map = {
            "PAUSE": "PAUSE",
            "RESUME": "RESUME",
            "ESTOP": "ESTOP",
            "CANCEL": "CANCEL",
            "CANCEL_ALL": "CANCEL",
        }
        if normalized not in command_map:
            return JobOrderResult(
                success=False,
                message=(
                    f"Unsupported command '{command}'. "
                    "Allowed: PAUSE, RESUME, ESTOP, CANCEL"
                ),
            )

        channel = f"robot:{robot_name}:command"
        payload = json.dumps({
            "op": "control",
            "topic": "/travel_command",
            "msg": {
                "command": command_map[normalized],
            },
        })
        try:
            await with_redis(
                f"publish:{channel}",
                lambda r: r.publish(channel, payload),
            )
            return JobOrderResult(
                success=True,
                message=f"{command_map[normalized]} dispatched to {robot_name}",
            )
        except Exception as exc:  # noqa: BLE001
            return JobOrderResult(
                success=False,
                message=f"Redis error dispatching {normalized} to {robot_name}: {exc}",
            )

    @strawberry.mutation
    async def run_robot(self, robot_name: str) -> JobOrderResult:
        return JobOrderResult(success=False, message="Not implemented in simulation mode")

    @strawberry.mutation
    async def set_autorun(self, robot_name: str, autorun: bool) -> Robot:
        return await fetch_robot(robot_name)

    @strawberry.mutation
    async def cancel_current_job(self, robot_name: str) -> JobOrderResult:
        return JobOrderResult(success=False, message="Not implemented in simulation mode")

    @strawberry.mutation
    async def clear_robot_error(self, robot_name: str) -> Robot:
        return await fetch_robot(robot_name)


@strawberry.type
class Subscription:
    @strawberry.subscription(description="Subscribe to all robots' state updates.")
    async def robots(self) -> AsyncGenerator[list[Robot], None]:
        robot_names = list(ROBOTS_CONFIG.keys())
        channels = [f"robot:{name}" for name in robot_names]
        while True:
            pubsub = None
            try:
                r = await get_redis()
                pubsub = r.pubsub()
                await pubsub.subscribe(*channels)
                async for message in pubsub.listen():
                    if message.get("type") == "message":
                        yield await fetch_all_robots()
            except Exception as exc:
                log.error(f"Redis subscription error (robots): {exc}. Reconnecting...")
                await asyncio.sleep(0.5)
            finally:
                if pubsub is not None:
                    try:
                        await pubsub.unsubscribe(*channels)
                    except Exception:
                        pass
                    try:
                        await pubsub.aclose()
                    except Exception:
                        pass

    @strawberry.subscription(description="Subscribe to a specific robot's state updates.")
    async def robot(self, name: str) -> AsyncGenerator[Optional[Robot], None]:
        if name not in ROBOTS_CONFIG:
            yield None
            return
        channel = f"robot:{name}"
        while True:
            pubsub = None
            try:
                r = await get_redis()
                pubsub = r.pubsub()
                await pubsub.subscribe(channel)
                async for message in pubsub.listen():
                    if message.get("type") == "message":
                        yield await fetch_robot(name)
            except Exception as exc:
                log.error(f"Redis subscription error (robot:{name}): {exc}. Reconnecting...")
                await asyncio.sleep(0.5)
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


# ── App ───────────────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    for _ in range(30):
        try:
            r = await get_redis(force_reconnect=(_ > 0))
            await r.ping()
            print(f"Redis connected at {REDIS_HOST}:{REDIS_PORT}")
            break
        except Exception as e:
            print(f"Waiting for Redis... ({e})")
            import asyncio
            await asyncio.sleep(2)

    print(f"Robots configured: {list(ROBOTS_CONFIG.keys())}")
    yield
    if _redis:
        await _redis.aclose()


schema = strawberry.Schema(query=Query, mutation=Mutation, subscription=Subscription)

graphql_ide = os.getenv("GRAPHQL_IDE", "graphiql")
graphql_router = GraphQLRouter(
    schema,
    graphql_ide=graphql_ide,  # type: ignore[arg-type]
)

app = FastAPI(title="Fleet Gateway", lifespan=lifespan)
app.include_router(graphql_router, prefix="/graphql")


@app.get("/health")
async def health():
    return {"status": "ok", "robots": list(ROBOTS_CONFIG.keys())}
