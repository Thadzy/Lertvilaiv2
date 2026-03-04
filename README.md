# WCS — Warehouse Control System

A distributed system for managing autonomous mobile robot (AMR) fleets in a warehouse environment. Handles order dispatch, route optimization, and real-time robot coordination.

## Architecture

```
                        Clients
                           │
                    GraphQL (8080)
                           │
                  ┌────────▼────────┐
                  │  Fleet Gateway  │  Python · FastAPI · Strawberry
                  │   (port 8000)   │
                  └─┬───────┬───────┘
                    │       │
             ┌──────▼──┐  ┌─▼──────────────┐
             │  Redis  │  │  Kong (8000)   │  Supabase API gateway
             │  (6379) │  └─┬──────┬───────┘
             └─────────┘    │      │
                        ┌───▼──┐ ┌─▼───────┐
                        │ REST │ │ Storage │  PostgREST + Storage API
                        └───┬──┘ └─────────┘
                            │
                   ┌────────▼────────┐
                   │   PostgreSQL    │  supabase/postgres
                   │  + pgRouting    │  (port 5432)
                   └────────┬────────┘
                            │
                  ┌─────────▼─────────┐
                  │    VRP Server     │  C++ · Crow · OR-Tools
                  │    (port 18080)   │
                  └───────────────────┘

                  ROS Robots (roslibpy WebSocket)
                  ← direct TCP from Fleet Gateway →
```

## Services

| Service | Image / Build | Host Port | Description |
|---|---|---|---|
| `db` | `supabase/postgres:15.8.1.085` | 5432 | PostgreSQL with pgRouting and all Supabase extensions |
| `rest` | `postgrest/postgrest:v14.5` | — | REST API over Postgres (via Kong) |
| `meta` | `supabase/postgres-meta:v0.95.2` | — | Postgres introspection for Studio |
| `storage` | `supabase/storage-api:v1.37.8` | — | File storage API (via Kong) |
| `studio` | `supabase/studio:2026.02.16` | 54323 | Supabase Studio UI |
| `kong` | `kong:2.8.1` | 8000 | API gateway — routes `/rest/v1/`, `/storage/v1/`, `/pg/` |
| `redis` | `redis:7-alpine` | 6379 | Job queue for Fleet Gateway |
| `vrp_server` | `./vrp_server` | 18080 | Vehicle Routing Problem solver |
| `fleet_gateway` | `./fleet_gateway` | 8080 | GraphQL API for order dispatch |

## Quick Start

### 1. Configure environment

```bash
cp .env.example .env
```

Edit `.env` and fill in the required values:

- `POSTGRES_PASSWORD` — choose a strong password
- `JWT_SECRET` — random string, minimum 32 characters
- `ANON_KEY` / `SERVICE_ROLE_KEY` — generate from your JWT secret:
  ```
  npx supabase@latest gen keys --project-ref local
  ```
  or use the [Supabase key generator](https://supabase.com/docs/guides/self-hosting/docker#generate-api-keys)
- `PG_META_CRYPTO_KEY` — random string, minimum 32 characters
- `ROBOTS_CONFIG` — JSON map of robot names to connection config (see Fleet Gateway docs)

### 2. Apply the warehouse graph schema

The graph schema (pgRouting tables and functions) must be loaded into the database once:

```bash
# After the db container is running:
docker compose up db -d
docker compose exec db psql -U postgres -f /dev/stdin < vrp_server/db/graph/merged.sql
```

Or apply it via Supabase Studio (port 54323) → SQL Editor.

### 3. Start all services

```bash
docker compose up --build
```

### 4. Access

| Interface | URL |
|---|---|
| Fleet Gateway GraphQL | http://localhost:8080/graphql |
| Supabase API | http://localhost:8000 |
| Supabase Studio | http://localhost:54323 |
| VRP Server | http://localhost:18080 |

Studio login uses `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` from your `.env`.

## Repository Structure

```
wcs/
├── docker-compose.yml          # Unified stack
├── .env.example                # Environment variable template
│
├── fleet_gateway/              # Python · FastAPI · Strawberry GraphQL
│   ├── main.py
│   ├── fleet_gateway/
│   │   ├── api/                # GraphQL schema + types
│   │   ├── warehouse_controller.py
│   │   ├── fleet_handler.py
│   │   ├── robot.py            # ROS integration via roslibpy
│   │   ├── route_oracle.py     # Supabase path planning
│   │   └── order_store.py      # Redis persistence
│   └── README.md               # GraphQL API reference
│
├── vrp_server/                 # C++17 · Crow · OR-Tools
│   ├── src/vrp_server.cpp
│   ├── include/
│   │   ├── vrp_solver.hpp      # OR-Tools VRP solver
│   │   └── db_connector.hpp    # PostgreSQL queries
│   ├── db/graph/               # Warehouse graph SQL schema
│   │   ├── merged.sql          # Deploy this — all-in-one
│   │   └── README.md           # Graph API reference
│   └── README.md               # VRP API reference
│
├── supabase/
│   └── config.toml             # Supabase CLI config (local dev)
│
└── volumes/                    # Runtime mounts
    ├── api/kong.yml            # Kong declarative config
    ├── db/                     # Postgres init scripts
    │   ├── roles.sql           # User passwords
    │   ├── jwt.sql             # JWT settings
    │   ├── webhooks.sql        # supabase_functions schema
    │   └── _supabase.sql       # _supabase database
    ├── storage/                # Uploaded files
    ├── snippets/               # Studio SQL snippets
    └── functions/              # Studio Edge Function stubs
```

## Service Documentation

- **Fleet Gateway** — [`fleet_gateway/README.md`](fleet_gateway/README.md): GraphQL schema, mutations, queries, robot configuration
- **VRP Server** — [`vrp_server/README.md`](vrp_server/README.md): `/solve` API, request format, constraints
- **Warehouse Graph** — [`vrp_server/db/graph/README.md`](vrp_server/db/graph/README.md): SQL schema, pgRouting functions, graph management

## Environment Variables

See [`.env.example`](.env.example) for the full list with descriptions.

Key variables:

| Variable | Description |
|---|---|
| `POSTGRES_PASSWORD` | Postgres superuser password |
| `JWT_SECRET` | JWT signing secret (32+ chars) |
| `ANON_KEY` | Supabase anon JWT |
| `SERVICE_ROLE_KEY` | Supabase service role JWT |
| `PG_META_CRYPTO_KEY` | postgres-meta encryption key (32+ chars) |
| `GRAPH_ID` | Warehouse graph ID used by Fleet Gateway |
| `ROBOTS_CONFIG` | JSON map of robot name → `{host, port, cell_heights}` |

## Individual Service Development

Each service can be run in isolation with its own `docker-compose.yml`:

```bash
# Fleet Gateway + Redis only
cd fleet_gateway && docker compose up --build

# VRP Server + Postgres only
cd vrp_server && docker compose up --build
```
