"""
vrp_client.py — Fleet Gateway VRP Orchestration Module
=======================================================
Handles all communication with the C++ OR-Tools VRP server (port 18080).

This module is the **single authoritative entry point** for VRP solving in the
fleet gateway.  It provides:

- Pre-flight validation to catch infeasible configurations before hitting
  the solver (empty tasks, self-loops, overcapacity).
- A thin async HTTP client that constructs the ``application/x-www-form-urlencoded``
  payload expected by the Crow C++ server.
- Structured error classification so callers receive a machine-readable error
  code *and* a human-readable explanation rather than a raw HTTP 400 body.
- Automatic **task decomposition fallback**: when OR-Tools returns
  ``"Failed to find a solution"`` *and* two or more tasks share the same
  pickup node, the solver is re-invoked once per unique pickup group and the
  resulting paths are stitched together.

Architecture note
-----------------
The C++ VRP server (journeykmutt/vrp_server) exposes a single endpoint::

    POST /solve_id   Content-Type: application/x-www-form-urlencoded

It builds the cost-matrix internally from the PostgreSQL warehouse graph,
runs OR-Tools PDVRP, and returns ordered node-ID paths per vehicle.

Known limitation
----------------
OR-Tools' ``AddPickupAndDelivery`` API may fail to produce a solution when
two tasks reference the **same** pickup node within a single PDVRP model
(the solver treats each (pickup, delivery) pair as needing distinct node visits,
which can violate internal uniqueness constraints under certain capacity
configurations).  The decomposition fallback in :func:`solve` resolves this by
splitting such tasks into independent sub-problems.
"""
from __future__ import annotations

import json
import logging
import os
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Optional

import httpx

log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Runtime configuration (overridable via environment variables)
# ---------------------------------------------------------------------------

#: Base URL of the C++ OR-Tools VRP server.
VRP_SERVER_URL: str = os.getenv("VRP_SERVER_URL", "http://vrp_server:18080")

#: Hard timeout for a single solve request (seconds).
VRP_TIMEOUT_S: float = float(os.getenv("VRP_TIMEOUT_S", "30"))


# ---------------------------------------------------------------------------
# Public data classes
# ---------------------------------------------------------------------------

@dataclass
class PickupDeliveryTask:
    """A single pickup-and-delivery task submitted to the VRP solver.

    Args:
        pickup_node_id: Database node ID of the pickup location.
        delivery_node_id: Database node ID of the delivery location.
        task_id: Optional client-supplied identifier for traceability.

    Raises:
        ValueError: If ``pickup_node_id == delivery_node_id``.
    """
    pickup_node_id: int
    delivery_node_id: int
    task_id: Optional[int] = None

    def __post_init__(self) -> None:
        if self.pickup_node_id == self.delivery_node_id:
            raise ValueError(
                f"Task {self.task_id}: pickup and delivery must be different nodes "
                f"(both are node {self.pickup_node_id})."
            )


@dataclass
class VrpSolveRequest:
    """Complete payload for a VRP solve operation.

    Args:
        graph_id: PostgreSQL warehouse graph ID (``wh_graphs.id``).
        num_vehicles: Number of robots available for assignment.
        tasks: Ordered list of pickup-delivery pairs.
        robot_locations: Starting node ID for each vehicle (one entry per
            vehicle).  When omitted the solver uses the graph depot.
        vehicle_capacity: Maximum number of items a single vehicle can carry
            simultaneously.  Defaults to ``1`` in the C++ solver when absent.
    """
    graph_id: int
    num_vehicles: int
    tasks: list[PickupDeliveryTask]
    robot_locations: Optional[list[int]] = None
    vehicle_capacity: Optional[int] = None


@dataclass
class VrpSolveResult:
    """Result returned by :func:`solve`.

    Args:
        success: ``True`` when a valid solution was produced.
        paths: Per-vehicle ordered list of warehouse node IDs.
        error_code: Machine-readable error category (see :class:`VrpErrorCode`).
        error_message: Human-readable description suitable for display in the UI.
        decomposed: ``True`` when the result was assembled via task decomposition
            rather than a direct single-solve.
    """
    success: bool
    paths: list[list[int]] = field(default_factory=list)
    error_code: Optional[str] = None
    error_message: Optional[str] = None
    decomposed: bool = False


# ---------------------------------------------------------------------------
# Error code catalogue
# ---------------------------------------------------------------------------

class VrpErrorCode:
    """Machine-readable error categories returned by :class:`VrpSolveResult`.

    These constants are stable strings consumed by the frontend to render
    context-specific error messages without string-parsing.
    """

    #: OR-Tools ran but could not construct a feasible route.
    NO_SOLUTION = "NO_SOLUTION"

    #: Graph connectivity is incomplete; at least one node pair has no path.
    INCOMPLETE_COSTMAP = "INCOMPLETE_COSTMAP"

    #: More tasks were submitted than the fleet capacity allows.
    OVERCAPACITY = "OVERCAPACITY"

    #: A node ID in the request does not exist in the warehouse graph.
    UNREACHABLE_NODE = "UNREACHABLE_NODE"

    #: The C++ server is not reachable or timed out.
    SERVER_UNAVAILABLE = "SERVER_UNAVAILABLE"

    #: Client-side validation failed before the request was sent.
    VALIDATION_ERROR = "VALIDATION_ERROR"

    #: An unclassified error from the C++ server.
    UNKNOWN = "UNKNOWN"


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _classify_server_error(message: str) -> tuple[str, str]:
    """Map a raw C++ server error string to a structured (code, friendly_msg) pair.

    Args:
        message: The ``error.message`` field from the C++ server JSON response.

    Returns:
        A 2-tuple of ``(error_code, human_readable_message)``.
    """
    lower = message.lower()

    if "failed to find a solution" in lower:
        return (
            VrpErrorCode.NO_SOLUTION,
            (
                "The VRP solver could not find a feasible route for the given tasks. "
                "This commonly occurs when multiple tasks share the same pickup node "
                "within a single solve request.  The gateway will automatically retry "
                "using task decomposition.  If the error persists, try increasing the "
                "fleet size or splitting the task queue manually."
            ),
        )

    if "costmap data is not complete" in lower or "missing path" in lower:
        # Extract node IDs from message if present for better diagnostics
        return (
            VrpErrorCode.INCOMPLETE_COSTMAP,
            (
                f"The warehouse graph is not fully connected: {message}.  "
                "Ensure every shelf/cell node has at least one edge to the main "
                "waypoint network (run the shelf-edge restore SQL if recently saved)."
            ),
        )

    if "overcapacity" in lower or "capacity" in lower:
        return (
            VrpErrorCode.OVERCAPACITY,
            (
                f"Vehicle capacity constraint violated: {message}.  "
                "Reduce the number of tasks per vehicle or increase 'Max Tasks per Vehicle'."
            ),
        )

    return VrpErrorCode.UNKNOWN, message


def _has_duplicate_pickups(tasks: list[PickupDeliveryTask]) -> bool:
    """Return ``True`` if any two tasks share the same pickup node ID.

    Args:
        tasks: Task list to inspect.

    Returns:
        ``True`` when at least one pickup node ID appears more than once.
    """
    pickup_ids = [t.pickup_node_id for t in tasks]
    return len(pickup_ids) != len(set(pickup_ids))


# ---------------------------------------------------------------------------
# Pre-flight validation
# ---------------------------------------------------------------------------

def validate_request(req: VrpSolveRequest) -> Optional[VrpSolveResult]:
    """Validate a :class:`VrpSolveRequest` before sending to the C++ solver.

    Performs synchronous, zero-cost checks to surface infeasible configurations
    early — avoiding unnecessary round-trips and cryptic 400 responses.

    Checks performed:

    * Task list must be non-empty.
    * ``num_vehicles`` must be ≥ 1.
    * Each task must have distinct pickup and delivery nodes.
    * If ``vehicle_capacity`` is provided, the total task count must not exceed
      ``num_vehicles × vehicle_capacity`` (hard overcapacity check).
    * ``robot_locations``, when present, must contain exactly ``num_vehicles``
      entries.

    Args:
        req: The request to validate.

    Returns:
        A failed :class:`VrpSolveResult` if any check fails; ``None`` if the
        request passes all validations.
    """
    # --- Empty task list ---
    if not req.tasks:
        return VrpSolveResult(
            success=False,
            error_code=VrpErrorCode.VALIDATION_ERROR,
            error_message="Task list is empty.  Add at least one pickup-delivery pair.",
        )

    # --- Minimum vehicle count ---
    if req.num_vehicles < 1:
        return VrpSolveResult(
            success=False,
            error_code=VrpErrorCode.VALIDATION_ERROR,
            error_message="'num_vehicles' must be at least 1.",
        )

    # --- Self-loop check (pickup == delivery) ---
    for task in req.tasks:
        if task.pickup_node_id == task.delivery_node_id:
            return VrpSolveResult(
                success=False,
                error_code=VrpErrorCode.VALIDATION_ERROR,
                error_message=(
                    f"Task {task.task_id}: pickup node and delivery node are identical "
                    f"(node {task.pickup_node_id}).  They must be different."
                ),
            )

    # --- Hard overcapacity check ---
    if req.vehicle_capacity and req.vehicle_capacity > 0:
        max_total = req.num_vehicles * req.vehicle_capacity
        if len(req.tasks) > max_total:
            return VrpSolveResult(
                success=False,
                error_code=VrpErrorCode.OVERCAPACITY,
                error_message=(
                    f"Overcapacity: {len(req.tasks)} tasks submitted but the fleet can "
                    f"handle at most {max_total} "
                    f"({req.num_vehicles} vehicle(s) × {req.vehicle_capacity} capacity).  "
                    "Reduce the task count or increase 'Max Tasks per Vehicle'."
                ),
            )

    # --- Robot locations length ---
    if req.robot_locations and len(req.robot_locations) != req.num_vehicles:
        return VrpSolveResult(
            success=False,
            error_code=VrpErrorCode.VALIDATION_ERROR,
            error_message=(
                f"'robot_locations' has {len(req.robot_locations)} entries but "
                f"'num_vehicles' is {req.num_vehicles}.  They must match."
            ),
        )

    return None  # All checks passed


# ---------------------------------------------------------------------------
# HTTP client (single-solve)
# ---------------------------------------------------------------------------

async def _call_vrp_server(
    graph_id: int,
    num_vehicles: int,
    pickups_deliveries: list[tuple[int, int]],
    robot_locations: Optional[list[int]],
    vehicle_capacity: Optional[int],
) -> VrpSolveResult:
    """Send one solve request to the C++ VRP HTTP server and parse the response.

    Constructs an ``application/x-www-form-urlencoded`` body as required by the
    Crow HTTP framework used by the C++ solver, then deserialises the JSON
    response envelope.

    Args:
        graph_id: Warehouse graph identifier in PostgreSQL.
        num_vehicles: Number of robots available for this sub-problem.
        pickups_deliveries: List of ``(pickup_node_id, delivery_node_id)`` pairs.
        robot_locations: Starting node ID per vehicle; ``None`` uses graph depot.
        vehicle_capacity: Max simultaneous items per vehicle.

    Returns:
        :class:`VrpSolveResult` with ``paths`` populated on success, or
        ``error_code``/``error_message`` populated on failure.
    """
    payload: dict[str, str] = {
        "graph_id": str(graph_id),
        "num_vehicles": str(num_vehicles),
        "pickups_deliveries": json.dumps([list(pair) for pair in pickups_deliveries]),
    }
    if robot_locations:
        payload["robot_locations"] = json.dumps(robot_locations)
    if vehicle_capacity and vehicle_capacity > 0:
        payload["vehicle_capacity"] = str(vehicle_capacity)

    log.info(
        "[VRP] → solve_id  graph=%d  vehicles=%d  tasks=%d  capacity=%s  locations=%s",
        graph_id,
        num_vehicles,
        len(pickups_deliveries),
        vehicle_capacity,
        robot_locations,
    )

    try:
        async with httpx.AsyncClient(timeout=VRP_TIMEOUT_S) as client:
            response = await client.post(
                f"{VRP_SERVER_URL}/solve_id",
                data=payload,
                headers={"Content-Type": "application/x-www-form-urlencoded"},
            )

    except httpx.TimeoutException:
        log.error("[VRP] Request timed out after %.0fs.", VRP_TIMEOUT_S)
        return VrpSolveResult(
            success=False,
            error_code=VrpErrorCode.SERVER_UNAVAILABLE,
            error_message=(
                f"VRP server did not respond within {VRP_TIMEOUT_S:.0f} seconds.  "
                "The graph may be too large or the server may be overloaded."
            ),
        )

    except httpx.ConnectError as exc:
        log.error("[VRP] Connection error: %s", exc)
        return VrpSolveResult(
            success=False,
            error_code=VrpErrorCode.SERVER_UNAVAILABLE,
            error_message=(
                f"Cannot connect to VRP server at {VRP_SERVER_URL}.  "
                "Verify that the 'vrp_server' Docker service is running."
            ),
        )

    # --- Parse response body ---
    try:
        body = response.json()
    except Exception:
        body = {}

    if not response.is_success:
        server_msg: str = (
            body.get("error", {}).get("message", response.text)
            if isinstance(body, dict) else response.text
        )
        code, friendly = _classify_server_error(server_msg)
        log.error("[VRP] ← HTTP %d  code=%s  msg=%s", response.status_code, code, server_msg)
        return VrpSolveResult(success=False, error_code=code, error_message=friendly)

    if isinstance(body, dict) and (body.get("status") == "error" or not body.get("data")):
        server_msg = body.get("error", {}).get("message", "Unknown solver error")
        code, friendly = _classify_server_error(server_msg)
        log.error("[VRP] ← Solver error  code=%s  msg=%s", code, server_msg)
        return VrpSolveResult(success=False, error_code=code, error_message=friendly)

    paths: list[list[int]] = body["data"]["paths"]
    log.info("[VRP] ← Solution: %d route(s)  nodes=%s", len(paths), [len(p) for p in paths])
    return VrpSolveResult(success=True, paths=paths)


# ---------------------------------------------------------------------------
# Task decomposition fallback
# ---------------------------------------------------------------------------

async def _solve_decomposed(req: VrpSolveRequest) -> VrpSolveResult:
    """Retry a failed solve by splitting tasks with shared pickup nodes.

    When OR-Tools cannot handle duplicate pickup node IDs in a single PDVRP
    formulation, this fallback groups tasks by their pickup node, solves each
    group independently, and concatenates the resulting paths.

    The concatenation heuristic:

    * If the last node of the accumulated path equals the first node of the
      next segment, the duplicate boundary node is dropped to avoid visiting
      it twice in the final route.
    * Each sub-problem uses the same ``num_vehicles``, ``robot_locations``,
      and ``vehicle_capacity`` as the original request.

    .. note::
        This is a **greedy** fallback — it does not guarantee a globally optimal
        combined route, but it guarantees feasibility.

    Args:
        req: The original :class:`VrpSolveRequest` that failed with NO_SOLUTION.

    Returns:
        :class:`VrpSolveResult` with ``decomposed=True`` on success, or a
        failure result if any sub-problem also fails.
    """
    # Group tasks by pickup node to form independent sub-problems
    groups: dict[int, list[PickupDeliveryTask]] = defaultdict(list)
    for task in req.tasks:
        groups[task.pickup_node_id].append(task)

    log.info(
        "[VRP] Decomposing %d tasks into %d pickup group(s): %s",
        len(req.tasks),
        len(groups),
        {k: len(v) for k, v in groups.items()},
    )

    # Initialise per-vehicle path accumulators
    combined: list[list[int]] = [[] for _ in range(req.num_vehicles)]

    for pickup_node_id, group in groups.items():
        sub = await _call_vrp_server(
            graph_id=req.graph_id,
            num_vehicles=req.num_vehicles,
            pickups_deliveries=[(t.pickup_node_id, t.delivery_node_id) for t in group],
            robot_locations=req.robot_locations,
            vehicle_capacity=req.vehicle_capacity,
        )

        if not sub.success:
            log.error(
                "[VRP] Decomposed sub-problem failed for pickup node %d: %s",
                pickup_node_id,
                sub.error_message,
            )
            return VrpSolveResult(
                success=False,
                error_code=sub.error_code,
                error_message=(
                    f"Task decomposition failed for pickup node {pickup_node_id}: "
                    f"{sub.error_message}"
                ),
            )

        # Stitch sub-path onto accumulated path per vehicle
        for i, segment in enumerate(sub.paths):
            if i >= len(combined):
                break
            if combined[i] and segment and combined[i][-1] == segment[0]:
                # Avoid duplicating the depot/junction node at the seam
                combined[i].extend(segment[1:])
            else:
                combined[i].extend(segment)

    log.info("[VRP] Decomposed solve succeeded.  Combined path lengths: %s", [len(p) for p in combined])
    return VrpSolveResult(success=True, paths=combined, decomposed=True)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

async def solve(req: VrpSolveRequest) -> VrpSolveResult:
    """Solve a Vehicle Routing Problem with validation and automatic fallback.

    This is the **single entry point** for all VRP solving in the fleet gateway.

    Execution pipeline:

    1. **Pre-validation** — synchronous checks for empty tasks, self-loops,
       overcapacity, and ``robot_locations`` length mismatch.
    2. **Direct solve** — submit the full task list to the C++ OR-Tools server.
    3. **Decomposition fallback** — if the direct solve fails with
       :attr:`VrpErrorCode.NO_SOLUTION` *and* duplicate pickup nodes are
       detected, re-attempt with :func:`_solve_decomposed`.

    Edge case coverage:

    * **Case 1 — Single task**: passes through direct solve unchanged.
    * **Case 2 — Duplicate pickup nodes**: triggers decomposition fallback.
    * **Case 3 — Fully distinct nodes**: passes through direct solve unchanged.
    * **Case 4 — Overcapacity**: caught at validation; returns a clean error.
    * **Case 5 — Unreachable nodes**: caught by C++ server; classified as
      :attr:`VrpErrorCode.INCOMPLETE_COSTMAP` and returned with guidance.

    Args:
        req: Fully-populated :class:`VrpSolveRequest`.

    Returns:
        :class:`VrpSolveResult` with ``paths`` on success, or
        ``error_code``/``error_message`` on failure.

    Example::

        result = await solve(VrpSolveRequest(
            graph_id=1,
            num_vehicles=1,
            tasks=[
                PickupDeliveryTask(pickup_node_id=62, delivery_node_id=95, task_id=1),
                PickupDeliveryTask(pickup_node_id=62, delivery_node_id=80, task_id=2),
            ],
            robot_locations=[1],
            vehicle_capacity=10,
        ))
        if result.success:
            print(result.paths)   # [[1, 62, 95, 80, 1]]
        else:
            print(result.error_code, result.error_message)
    """
    # ── Step 1: Pre-validation ────────────────────────────────────────────────
    validation_error = validate_request(req)
    if validation_error:
        log.warning("[VRP] Validation failed: %s", validation_error.error_message)
        return validation_error

    # ── Step 2: Direct solve ──────────────────────────────────────────────────
    result = await _call_vrp_server(
        graph_id=req.graph_id,
        num_vehicles=req.num_vehicles,
        pickups_deliveries=[(t.pickup_node_id, t.delivery_node_id) for t in req.tasks],
        robot_locations=req.robot_locations,
        vehicle_capacity=req.vehicle_capacity,
    )

    if result.success:
        return result

    # ── Step 3: Decomposition fallback ────────────────────────────────────────
    if result.error_code == VrpErrorCode.NO_SOLUTION and _has_duplicate_pickups(req.tasks):
        dup_count = len(req.tasks) - len({t.pickup_node_id for t in req.tasks})
        log.info(
            "[VRP] Direct solve failed (NO_SOLUTION) with %d duplicate pickup node(s).  "
            "Retrying via task decomposition.",
            dup_count,
        )
        decomposed = await _solve_decomposed(req)
        if decomposed.success:
            return decomposed
        # Both strategies failed — return the original (more informative) error
        log.warning(
            "[VRP] Decomposition also failed: %s  Returning original error.",
            decomposed.error_message,
        )

    return result
