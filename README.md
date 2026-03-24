# Warehouse Control System (WCS) — Edge-AI Fleet Management Platform
WCS is a production-oriented orchestration platform for autonomous warehouse fleets.  
It combines route optimization (VRP), graph-based navigation (A* + edge following), real-time telemetry visualization, and industrial safety controls (PAUSE, RESUME, ESTOP) into a single distributed system.

## What this platform does
- Plans multi-robot dispatch routes from warehouse tasks.
- Converts high-level route steps into robot travel commands.
- Streams robot state from ROS2 simulation/bridge into Redis and GraphQL.
- Visualizes fleet status and active paths in a React control surface.
- Enforces two layers of runtime safety:
  - Fleet-level dispatch loop controls (pause/resume/cancel/estop).
  - Robot-level control commands relayed to runtime motion topics.

## System architecture
Core data/control flow:

```text
React UI (Fleet/Optimization)
  -> GraphQL mutations/queries (fleet_gateway)
  -> Redis (state + pub/sub command channels)
  -> robot_bridge
  -> ROS2 rosbridge / simulator

React UI
  -> Supabase/PostgREST/PostgreSQL (warehouse graph, tasks, assignments)
  -> VRP service (route optimization)
```

Detailed operational flow:
1. Operator dispatches routes from the UI.
2. Frontend sends GraphQL mutations to `fleet_gateway`.
3. `fleet_gateway` publishes robot commands to Redis channels (`robot:{name}:command`).
4. `robot_bridge` consumes commands and publishes ROS-compatible payloads (for `/travel_command`).
5. `robot_bridge` also ingests robot telemetry (odometry, QR/tag, piggyback state), writes state keys and heartbeat keys to Redis, and publishes state notifications.
6. `fleet_gateway` resolves robot online/offline status from Redis heartbeat + state.
7. Frontend polling hook reads GraphQL robot state and renders live positions/status in React Flow.

## Key features
- **VRP integration**
  - Vehicle-index route planning with frontend dispatch orchestration.
  - Vehicle-to-robot mapping (`VEHICLE_ROBOT_MAP`) for physical assignment.
- **A* pathfinding and edge following**
  - Graph-backed navigation over warehouse nodes/edges.
  - Path overlays and per-robot active sequence visualization.
- **Real-time fleet telemetry**
  - Robot pose/status surfaced through GraphQL.
  - Connection-state-aware UI with reconnect and degradation handling.
- **Industrial safety controls**
  - PAUSE / RESUME / ESTOP / CANCEL command pipeline.
  - Fleet-wide dispatch cancellation and per-robot emergency controls.
  - Offline detection and fail-safe behavior on connectivity loss.

## Repository layout
```text
wcs/
  frontend/                React + TypeScript UI (graph editor, optimization, fleet)
  fleet_gateway_custom/    FastAPI + Strawberry GraphQL gateway
  robot_bridge/            Redis <-> ROS2 rosbridge bridge service
  db_schema/               Warehouse graph schema + sample layouts
  volumes/                 Kong and database bootstrap assets
  docker-compose.yml       Full stack orchestration
  env_init.sh              Environment bootstrap script
```

## Prerequisites
- Docker Desktop (or Docker Engine + Compose plugin)
- Git
- Bash-compatible shell for setup scripts

## Setup and run (production-like local stack)
1. Clone and enter the repository:
```bash
git clone <your-repo-url>
cd wcs
```

2. Initialize environment:
```bash
./env_init.sh
```
If not executable:
```bash
chmod +x env_init.sh
./env_init.sh
```

3. Start all services:
```bash
docker compose up -d --build
```

4. Load warehouse graph data (example):
```bash
docker exec -i wcs-db-1 psql -U postgres < db_schema/graph_layout/sample_dummy.sql
```
Or a larger layout:
```bash
docker exec -i wcs-db-1 psql -U postgres < db_schema/graph_layout/sample_fibo_6fl.sql
```

5. Verify service health:
- Fleet Gateway GraphQL: `http://localhost:8080/graphql`
- Supabase/Kong API: `http://localhost:8000`
- Supabase Studio: `http://localhost:54323`
- VRP service health: `http://localhost:18080/health`
- ROS bridge simulator websocket: `ws://localhost:9090`

## Frontend and control behavior
- Fleet UI polls GraphQL robot state at fixed intervals.
- On backend timeout/5xx degradation, robots are explicitly marked `offline` in UI state.
- Dispatching a new route batch aborts any previously active dispatch loops before starting new loops.
- Missing map lookups (vehicle map, alias map, cell/node map) use safe fallbacks to avoid runtime crashes.
- React Flow path edges are only drawn when source/target node IDs exist.

## Primary GraphQL API reference
Endpoint:
```text
POST http://localhost:8080/graphql
```

Common queries:
```graphql
query {
  robots {
    name
    connectionStatus
    lastActionStatus
    mobileBaseState {
      pose { x y a timestamp }
      tag { qrId timestamp }
    }
  }
}
```

Common mutations:
```graphql
mutation SendTravel($order: TravelOrderInput!) {
  sendTravelOrder(order: $order) {
    success
    message
  }
}
```

```graphql
mutation SendRobotCommand($robotName: String!, $command: String!) {
  sendRobotCommand(robotName: $robotName, command: $command) {
    success
    message
  }
}
```

Travel input payload fields:
- `robotName`
- `targetNodeAlias` (preferred for graph navigation)
- `targetX`, `targetY` (optional direct coordinates)

Robot control command values:
- `PAUSE`
- `RESUME`
- `ESTOP`
- `CANCEL`
- `CANCEL_ALL` (normalized to `CANCEL`)

## ROS2 / bridge topic reference
Inbound telemetry consumed by `robot_bridge`:
- `/odom_qr` (`nav_msgs/msg/Odometry`) for pose/speed/online health
- `/qr_id` (`std_msgs/msg/String`) for current QR/tag alias
- `/piggyback_state` (`sensor_msgs/msg/JointState`) for mechanism state

Outbound control emitted by `robot_bridge`:
- `/travel_command` (payload forwarded via rosbridge publish op)

Redis channels/keys:
- Command channel: `robot:{robot_name}:command`
- State key: `robot:{robot_name}:state`
- Heartbeat key: `robot:{robot_name}:heartbeat`
- Pub/sub state fanout: `robot:{robot_name}`

## Fault tolerance and production hardening
- Redis publish/subscribe operations are wrapped with retries and reconnect logic in both gateway and bridge.
- Command relay in `robot_bridge` validates JSON structure, operation type, and command fields before processing.
- If odometry becomes stale, bridge marks robot offline and removes heartbeat so gateway/frontend propagate `OFFLINE` quickly.
- Subscription streams in `fleet_gateway` automatically recover after Redis disconnects.

## Operational commands
Tail logs:
```bash
docker compose logs -f fleet_gateway robot_bridge frontend vrp_server
```

Restart a single service:
```bash
docker compose restart fleet_gateway
```

Stop stack:
```bash
docker compose down
```

Stop and remove volumes (destructive):
```bash
docker compose down -v
```

## Notes for production deployment
- Use persistent Redis and PostgreSQL volumes.
- Place `fleet_gateway` and `robot_bridge` behind monitored process supervision.
- Configure reverse proxy, TLS, and auth at the ingress layer.
- Add centralized logging/metrics and health probes for all critical services.
- Use CI checks (lint/type/test) and environment-specific `.env` secrets management.
