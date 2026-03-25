"""
route_oracle.py — Fleet Gateway Route Expansion & Logging
==========================================================

Responsible for expanding the **high-level VRP node-ID paths** returned by
the C++ OR-Tools solver into **fully-detailed, waypoint-by-waypoint A* paths**
by querying the ``wh_astar_shortest_path`` PostgreSQL function via PostgREST.

Design principles
-----------------
* **Non-blocking**: All database calls are asynchronous (``httpx.AsyncClient``).
  Callers should schedule this module via ``asyncio.create_task()`` so that
  route expansion never delays the HTTP response sent to the frontend.
* **Batch alias resolution**: Node aliases (``Q9``, ``S1C1L3``, etc.) are
  resolved in a single PostgREST query per vehicle route rather than one
  query per node, minimising round-trips.
* **Graceful degradation**: Any PostgREST error causes the affected segment
  to fall back to raw node-ID notation in the log, so a connectivity issue
  never raises an unhandled exception in a background task.

PostgREST endpoints used
------------------------
``POST /rpc/wh_astar_shortest_path``
    Returns the ordered ``bigint[]`` of node IDs forming the shortest A*
    path between two warehouse nodes.

``GET /wh_nodes_view``
    Fetched with ``?select=id,alias&id=in.(...)`` to resolve node IDs to
    human-readable aliases in one round-trip.

Environment variables
---------------------
``POSTGREST_URL``
    Internal base URL of the PostgREST service.
    Default: ``http://rest:3000``

``SUPABASE_SERVICE_KEY``
    JWT used as the ``Authorization: Bearer`` token.  The service-role key
    is required to bypass Row-Level Security on the view.
"""
from __future__ import annotations

import asyncio
import logging
import os
from typing import Any, Optional

import httpx

log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Runtime configuration
# ---------------------------------------------------------------------------

#: Internal PostgREST base URL (reachable inside the Docker network).
POSTGREST_URL: str = os.getenv("POSTGREST_URL", "http://rest:3000")

#: Service-role JWT — bypasses RLS so fleet_gateway can read all graph data.
_SERVICE_KEY: str = os.getenv("SUPABASE_SERVICE_KEY", "")

#: HTTP timeout (seconds) for a single PostgREST call.
_HTTP_TIMEOUT: float = float(os.getenv("ROUTE_ORACLE_TIMEOUT_S", "10"))

# Shared headers injected into every PostgREST request.
_HEADERS: dict[str, str] = {
    "Content-Type": "application/json",
    "Accept": "application/json",
}
if _SERVICE_KEY:
    _HEADERS["Authorization"] = f"Bearer {_SERVICE_KEY}"


# ---------------------------------------------------------------------------
# Data helpers
# ---------------------------------------------------------------------------

def _flatten_unique(paths: list[list[int]]) -> set[int]:
    """Return the set of all distinct node IDs across all vehicle paths.

    Args:
        paths: Per-vehicle list of ordered node IDs from the VRP solver.

    Returns:
        Flat set of every unique node ID present in any path.
    """
    return {node_id for path in paths for node_id in path}


# ---------------------------------------------------------------------------
# PostgREST helpers
# ---------------------------------------------------------------------------

async def _fetch_astar_path(
    client: httpx.AsyncClient,
    graph_id: int,
    from_id: int,
    to_id: int,
) -> list[int]:
    """Call ``wh_astar_shortest_path`` for a single edge in the VRP route.

    Sends a POST request to ``/rpc/wh_astar_shortest_path`` and returns the
    ordered list of node IDs forming the A* shortest path.

    Args:
        client: A shared ``httpx.AsyncClient`` for connection reuse.
        graph_id: Warehouse graph identifier in PostgreSQL.
        from_id: Source node ID.
        to_id: Destination node ID.

    Returns:
        Ordered list of node IDs ``[from_id, ..., to_id]``.
        Returns ``[from_id, to_id]`` as a fallback if the RPC fails.
    """
    # Same-node edge — no movement required; return immediately
    if from_id == to_id:
        return [from_id]

    try:
        response = await client.post(
            f"{POSTGREST_URL}/rpc/wh_astar_shortest_path",
            json={
                "p_graph_id": graph_id,
                "p_start_vid": from_id,
                "p_end_vid": to_id,
            },
            headers=_HEADERS,
            timeout=_HTTP_TIMEOUT,
        )
        response.raise_for_status()

        data = response.json()

        # PostgREST can return a scalar bigint[] in two formats depending on
        # the server version and Content-Profile header:
        #
        #   Format A (most common): flat array of ints  →  [1, 5, 8, 62]
        #   Format B (wrapped):     [{"wh_astar_shortest_path": [1, 5, 8, 62]}]
        #
        # Handle both defensively.
        if isinstance(data, list) and data:
            first = data[0]
            if isinstance(first, int):
                # Format A — the list itself IS the path
                return [int(n) for n in data]
            if isinstance(first, dict):
                # Format B — unwrap the function-name key
                path_ids = next(iter(first.values()), None) or []
                if isinstance(path_ids, list) and path_ids:
                    return [int(n) for n in path_ids]

        log.warning(
            "[Route Oracle] Empty A* result for %d→%d. Using direct edge.",
            from_id, to_id,
        )
    except Exception as exc:
        log.warning(
            "[Route Oracle] A* call failed for %d→%d: %s. Using direct edge.",
            from_id, to_id, exc,
        )

    # Graceful fallback — show at least the two endpoint IDs
    return [from_id, to_id]


async def _batch_resolve_aliases(
    client: httpx.AsyncClient,
    graph_id: int,
    node_ids: set[int],
) -> dict[int, str]:
    """Resolve a set of node IDs to their human-readable aliases in one query.

    Calls ``GET /wh_nodes_view?select=id,alias&id=in.(...)`` to minimise
    PostgREST round-trips regardless of how many nodes are in the routes.

    Args:
        client: A shared ``httpx.AsyncClient`` for connection reuse.
        graph_id: Warehouse graph identifier (used to scope the query).
        node_ids: Set of node IDs to resolve.

    Returns:
        Mapping of ``{node_id: alias_string}``.  Nodes whose alias is
        ``None`` in the database fall back to ``"node-<id>"``.
    """
    if not node_ids:
        return {}

    id_csv = ",".join(str(n) for n in sorted(node_ids))

    try:
        response = await client.get(
            f"{POSTGREST_URL}/wh_nodes_view",
            params={
                "select": "id,alias",
                "graph_id": f"eq.{graph_id}",
                "id": f"in.({id_csv})",
            },
            headers=_HEADERS,
            timeout=_HTTP_TIMEOUT,
        )
        response.raise_for_status()

        return {
            int(row["id"]): (row["alias"] or f"node-{row['id']}")
            for row in response.json()
        }
    except Exception as exc:
        log.warning("[Route Oracle] Alias batch lookup failed: %s. Using node IDs.", exc)
        return {n: str(n) for n in node_ids}


# ---------------------------------------------------------------------------
# Core expansion logic
# ---------------------------------------------------------------------------

async def _expand_vehicle_path(
    client: httpx.AsyncClient,
    graph_id: int,
    vehicle_name: str,
    vrp_path: list[int],
    task_aliases: dict[int, str],
) -> None:
    """Expand one vehicle's VRP path into detailed A* segments and log it.

    For each consecutive pair ``(vrp_path[i], vrp_path[i+1])``, fetches the
    full A* waypoint sequence and emits one log line per task leg.  The
    output format is::

        [Route Oracle] Vehicle: FALCOBOT | Leg 1: __depot__ → S1C1L3
                       | Path: ['__depot__', 'Q9', 'Q12', 'Q71', 'S1C1L3']

    A summary line is emitted after all legs::

        [Route Oracle] Vehicle: FALCOBOT | Full route (9 waypoints):
                       __depot__ → Q9 → Q12 → Q71 → S1C1L3 → Q71 → Q12 → Q9 → __depot__

    Args:
        client: Shared ``httpx.AsyncClient`` for all sub-requests.
        graph_id: Warehouse graph identifier.
        vehicle_name: Display name for the vehicle (e.g. ``"FALCOBOT"``).
        vrp_path: Ordered node-ID list from the VRP solver
                  (e.g. ``[1, 62, 95, 1]``).
        task_aliases: Pre-fetched ``{node_id: alias}`` mapping for all
                      nodes that appear in ``vrp_path``.
    """
    if len(vrp_path) < 2:
        log.info("[Route Oracle] Vehicle: %s | No movement required.", vehicle_name)
        return

    # Expand every consecutive (from, to) pair concurrently for speed.
    # We use asyncio.gather to fire all A* calls in parallel.
    pairs = [(vrp_path[i], vrp_path[i + 1]) for i in range(len(vrp_path) - 1)]

    # Gather all A* segments in parallel — non-blocking I/O
    segments: list[list[int]] = await asyncio.gather(
        *[_fetch_astar_path(client, graph_id, f, t) for f, t in pairs]
    )

    # Build the full merged waypoint list (de-duplicate segment boundaries)
    full_path_ids: list[int] = []
    for segment in segments:
        if full_path_ids and segment and full_path_ids[-1] == segment[0]:
            full_path_ids.extend(segment[1:])
        else:
            full_path_ids.extend(segment)

    # Resolve IDs → aliases for the expanded set (segment mid-points may not
    # be in vrp_path, so we resolve the full expanded set here)
    expanded_ids = set(full_path_ids)
    extra_aliases = await _batch_resolve_aliases(client, graph_id, expanded_ids - set(task_aliases))
    alias_map = {**task_aliases, **extra_aliases}

    full_path_aliases = [alias_map.get(n, str(n)) for n in full_path_ids]

    # ── Log per-leg detail ────────────────────────────────────────────────────
    for idx, (segment_ids, (from_id, to_id)) in enumerate(zip(segments, pairs)):
        from_alias = alias_map.get(from_id, str(from_id))
        to_alias = alias_map.get(to_id, str(to_id))
        segment_aliases = [alias_map.get(n, str(n)) for n in segment_ids]

        log.info(
            "[Route Oracle] Vehicle: %s | Leg %d: %s → %s | Path: %s",
            vehicle_name,
            idx + 1,
            from_alias,
            to_alias,
            segment_aliases,
        )

    # ── Log full-route summary ────────────────────────────────────────────────
    log.info(
        "[Route Oracle] Vehicle: %s | Full route (%d waypoints): %s",
        vehicle_name,
        len(full_path_aliases),
        " → ".join(full_path_aliases),
    )


# ---------------------------------------------------------------------------
# Coordinate-aware node resolution (used by execute_path dispatch)
# ---------------------------------------------------------------------------

async def _batch_resolve_nodes_with_coords(
    client: httpx.AsyncClient,
    graph_id: int,
    node_ids: set[int],
) -> dict[int, dict[str, Any]]:
    """Resolve node IDs to alias + x/y coordinates in a single PostgREST query.

    Fetches ``id``, ``alias``, ``x``, and ``y`` from ``wh_nodes_view`` for all
    requested node IDs.  Results are keyed by node ID.

    Args:
        client: Shared ``httpx.AsyncClient`` for connection reuse.
        graph_id: Warehouse graph identifier (scopes the view query).
        node_ids: Set of node IDs to resolve.

    Returns:
        Mapping of ``{node_id: {"alias": str, "x": float, "y": float}}``.
        Missing or errored nodes fall back to ``alias="node-<id>"``,
        ``x=0.0``, ``y=0.0`` so the caller always receives a complete record.
    """
    if not node_ids:
        return {}

    id_csv = ",".join(str(n) for n in sorted(node_ids))
    fallback: dict[int, dict[str, Any]] = {
        n: {"alias": f"node-{n}", "x": 0.0, "y": 0.0} for n in node_ids
    }

    try:
        response = await client.get(
            f"{POSTGREST_URL}/wh_nodes_view",
            params={
                "select": "id,alias,x,y",
                "graph_id": f"eq.{graph_id}",
                "id": f"in.({id_csv})",
            },
            headers=_HEADERS,
            timeout=_HTTP_TIMEOUT,
        )
        response.raise_for_status()

        result: dict[int, dict[str, Any]] = {}
        for row in response.json():
            nid = int(row["id"])
            result[nid] = {
                "alias": row.get("alias") or f"node-{nid}",
                "x": float(row.get("x") or 0.0),
                "y": float(row.get("y") or 0.0),
            }
        # Fill in any IDs that were absent from the response
        for nid in node_ids:
            result.setdefault(nid, fallback[nid])
        return result

    except Exception as exc:
        log.warning(
            "[Route Oracle] Node coord batch lookup failed: %s. Using fallback zeros.", exc
        )
        return fallback


async def expand_path_with_coords(
    graph_id: int,
    vrp_path: list[int],
) -> list[dict[str, Any]]:
    """Expand a VRP node-ID path into an ordered waypoint list with coordinates.

    This is the **dispatch-oriented** counterpart of :func:`log_vehicle_routes`.
    Instead of logging, it returns the data needed to build an ``execute_path``
    Redis payload:

    .. code-block:: python

        [
            {"alias": "Q1",   "x": 1.23, "y": 4.56},
            {"alias": "Q9",   "x": 2.10, "y": 4.56},
            {"alias": "DOCK", "x": 3.45, "y": 6.78},
        ]

    Steps:

    1. For every consecutive ``(from, to)`` pair in ``vrp_path``, fetch the
       A* waypoint sequence in parallel.
    2. Merge segments (de-duplicating boundary nodes).
    3. Batch-resolve all unique node IDs to ``{alias, x, y}`` in one query.
    4. Return the ordered list of waypoint dicts.

    Args:
        graph_id: Warehouse graph identifier in PostgreSQL.
        vrp_path: Ordered list of VRP-level node IDs
                  (e.g. ``[1, 62, 95, 1]``).

    Returns:
        Ordered list of ``{"alias": str, "x": float, "y": float}`` dicts.
        Returns ``[]`` when ``vrp_path`` has fewer than two nodes.
    """
    if len(vrp_path) < 2:
        log.info("[Route Oracle] expand_path_with_coords: path too short, returning empty.")
        return []

    try:
        async with httpx.AsyncClient() as client:
            # ── Step 1: Fetch all A* sub-paths concurrently ──────────────────
            pairs = [(vrp_path[i], vrp_path[i + 1]) for i in range(len(vrp_path) - 1)]
            segments: list[list[int]] = await asyncio.gather(
                *[_fetch_astar_path(client, graph_id, f, t) for f, t in pairs]
            )

            # ── Step 2: Merge segments, de-duplicate shared boundary nodes ───
            full_path_ids: list[int] = []
            for segment in segments:
                if full_path_ids and segment and full_path_ids[-1] == segment[0]:
                    full_path_ids.extend(segment[1:])
                else:
                    full_path_ids.extend(segment)

            # ── Step 3: Resolve all unique IDs to alias + coordinates ────────
            unique_ids: set[int] = set(full_path_ids)
            node_map = await _batch_resolve_nodes_with_coords(client, graph_id, unique_ids)

            # ── Step 4: Build ordered waypoint list ──────────────────────────
            waypoints: list[dict[str, Any]] = [
                node_map.get(nid, {"alias": f"node-{nid}", "x": 0.0, "y": 0.0})
                for nid in full_path_ids
            ]

        log.info(
            "[Route Oracle] expand_path_with_coords: %d VRP nodes → %d waypoints.",
            len(vrp_path),
            len(waypoints),
        )
        return waypoints

    except Exception as exc:
        log.error("[Route Oracle] expand_path_with_coords failed: %s", exc)
        return []


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

async def log_vehicle_routes(
    graph_id: int,
    vehicle_names: list[str],
    paths: list[list[int]],
) -> None:
    """Expand and log A* detailed routes for all vehicles.

    This is the **single entry point** for route logging.  It is designed to
    be scheduled as a background task via ``asyncio.create_task()`` so that
    it never delays the VRP HTTP response to the frontend.

    Execution steps:

    1. Batch-resolve all node IDs across all paths to aliases in one request.
    2. For each vehicle, concurrently fetch A* paths for every consecutive
       node pair and log the result.

    Any failure during resolution is caught and logged as a warning; the
    function always completes without raising.

    Args:
        graph_id: Warehouse graph identifier in PostgreSQL.
        vehicle_names: Display name for each vehicle (one per path in
                       ``paths``).  If shorter than ``paths``, defaults to
                       ``"Vehicle-N"`` for out-of-range indices.
        paths: Per-vehicle ordered node-ID lists from :func:`vrp_client.solve`.
               Example: ``[[1, 62, 95, 1], [1, 80, 86, 1]]``.

    Example usage (fire-and-forget from an endpoint)::

        asyncio.create_task(
            log_vehicle_routes(
                graph_id=1,
                vehicle_names=["FALCOBOT"],
                paths=result.paths,
            )
        )
    """
    if not paths:
        return

    log.info(
        "[Route Oracle] Expanding A* paths for %d vehicle(s) on graph %d ...",
        len(paths),
        graph_id,
    )

    # Pre-fetch aliases for every node referenced in ANY path (one batch call)
    all_node_ids = _flatten_unique(paths)

    try:
        async with httpx.AsyncClient() as client:
            # Batch resolve all aliases up-front to share across vehicles
            alias_map = await _batch_resolve_aliases(client, graph_id, all_node_ids)

            # Expand each vehicle's path concurrently
            await asyncio.gather(
                *[
                    _expand_vehicle_path(
                        client=client,
                        graph_id=graph_id,
                        vehicle_name=(
                            vehicle_names[i]
                            if i < len(vehicle_names)
                            else f"Vehicle-{i + 1}"
                        ),
                        vrp_path=path,
                        task_aliases=alias_map,
                    )
                    for i, path in enumerate(paths)
                ]
            )

    except Exception as exc:
        # Background tasks must never propagate — log and swallow all errors
        log.error("[Route Oracle] Unexpected error during route expansion: %s", exc)
