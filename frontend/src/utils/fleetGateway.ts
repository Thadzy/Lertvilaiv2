/**
 * Fleet Gateway GraphQL Client
 * =============================
 * Communicates with `fleet_gateway_custom` (port 8080) through the Vite dev-server
 * reverse proxy configured at `/api/fleet` → `http://127.0.0.1:8080`.
 *
 * Responsibilities:
 *  - Provide a typed wrapper around the `sendTravelOrder` GraphQL mutation.
 *  - Maintain the authoritative mapping from VRP vehicle-index to physical robot name.
 *  - Orchestrate sequential dispatch of all key waypoints for a single vehicle route.
 *
 * Architecture note:
 *  The C++ VRP solver assigns vehicles by zero-based index (Vehicle 0, 1, 2 …).
 *  The fleet gateway identifies robots by name (e.g. "SIMBOT").
 *  `VEHICLE_ROBOT_MAP` is the single source of truth that bridges these two worlds.
 */

import type { DBNode } from '../types/database';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/**
 * Vite-proxied path to the Fleet Gateway GraphQL endpoint.
 * Proxy rule (vite.config.ts): `/api/fleet` → `http://127.0.0.1:8080`
 */
const FLEET_GW_URL = '/api/fleet/graphql';

/**
 * Maps each VRP vehicle index (0-based, as returned by the C++ solver) to the
 * physical robot name registered in the fleet gateway.
 *
 * - Vehicle index 0  →  "Vehicle 1" in the UI  →  real robot "SIMBOT"
 *
 * Extend this map when additional robots are commissioned.
 */
export const VEHICLE_ROBOT_MAP: Record<number, string> = {
  0: 'SIMBOT',
} as const;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/** Payload returned by the `sendTravelOrder` GraphQL mutation. */
export interface TravelOrderResult {
  success: boolean;
  message: string;
}
export interface RobotControlResult {
  success: boolean;
  message: string;
}

/** Aggregated result for a full vehicle-route dispatch. */
export interface RouteDispatchResult {
  /** The robot name that received the orders. */
  robotName: string;
  /** Number of travel orders successfully sent. */
  dispatched: number;
  /** Number of nodes skipped (depot, unknown IDs, etc.). */
  skipped: number;
  /** Per-node log entries for UI feedback. */
  log: string[];
}

// ---------------------------------------------------------------------------
// GraphQL helper
// ---------------------------------------------------------------------------

/**
 * Execute a raw GraphQL operation against the Fleet Gateway.
 *
 * Uses a plain `fetch` call — no Apollo or urql dependency required.
 * Throws on network errors, non-2xx HTTP responses, and GraphQL-level errors.
 *
 * @param query     - The GraphQL operation string.
 * @param variables - Optional variable map.
 * @returns The `data` portion of the GraphQL response.
 * @throws  Error with a human-readable message on any failure.
 */
async function gql<T = unknown>(
  query: string,
  variables?: Record<string, unknown>,
): Promise<T> {
  const res = await fetch(FLEET_GW_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ query, variables }),
    // Generous timeout — the mutation involves a Redis publish round-trip
    signal: AbortSignal.timeout(10_000),
  });

  if (!res.ok) {
    throw new Error(`Fleet Gateway returned HTTP ${res.status}`);
  }

  const body = await res.json();

  // Propagate the first GraphQL error as a standard JS Error
  if (body.errors?.length) {
    throw new Error(`GraphQL error: ${body.errors[0].message}`);
  }

  return body.data as T;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Send a single travel order to a named robot.
 *
 * Translates to the Fleet Gateway mutation:
 * ```graphql
 * mutation SendTravel($order: TravelOrderInput!) {
 *   sendTravelOrder(order: $order) { success message }
 * }
 * ```
 * On success the fleet gateway publishes a command to the Redis channel
 * `robot:{robotName}:command`, which the `robot_bridge` service picks up
 * and forwards to the ROS2 rosbridge `/travel_command` topic.
 *
 * @param robotName       - Registered robot name (e.g. "SIMBOT").
 * @param targetNodeAlias - Warehouse node alias (e.g. "Q10").
 * @returns               The mutation result `{ success, message }`.
 * @throws                Error if the GraphQL call fails or returns `success: false`.
 */
export async function sendTravelOrder(
  robotName: string,
  targetNodeAlias: string,
  targetX?: number,
  targetY?: number,
): Promise<TravelOrderResult> {
  const data = await gql<{ sendTravelOrder: TravelOrderResult }>(
    `mutation SendTravel($order: TravelOrderInput!) {
       sendTravelOrder(order: $order) { success message }
     }`,
    { order: { robotName, targetNodeAlias, targetX, targetY } },
  );

  const result = data.sendTravelOrder;

  if (!result.success) {
    // Surface fleet-gateway-level rejections as thrown errors so the caller
    // can handle them uniformly without inspecting the return value.
    throw new Error(`sendTravelOrder rejected: ${result.message}`);
  }

  return result;
}
export async function sendRobotControlCommand(
  robotName: string,
  command: 'PAUSE' | 'RESUME' | 'ESTOP' | 'CANCEL' | 'CANCEL_ALL',
): Promise<RobotControlResult> {
  const data = await gql<{ sendRobotCommand: RobotControlResult }>(
    `mutation SendRobotCommand($robotName: String!, $command: String!) {
       sendRobotCommand(robotName: $robotName, command: $command) { success message }
     }`,
    { robotName, command },
  );
  const result = data.sendRobotCommand;
  if (!result.success) {
    throw new Error(`sendRobotCommand rejected: ${result.message}`);
  }
  return result;
}

// ---------------------------------------------------------------------------
// Global State for Dispatch Control
// ---------------------------------------------------------------------------

/**
 * Global AbortController to manage the cancellation of active dispatch loops.
 * @type {AbortController}
 */
export let dispatchAbortController = new AbortController();
export let isFleetPaused = false;
export const setFleetPaused = (state: boolean): void => {
  isFleetPaused = state;
};

/**
 * Dispatch all key waypoints of a VRP vehicle route to its assigned robot.
 *
 * ## Vehicle → Robot mapping
 * `vehicleIndex` is the zero-based index from the VRP solver output
 * (Vehicle 0 = "Vehicle 1" in the UI). `VEHICLE_ROBOT_MAP` converts that
 * index into the physical robot name that the fleet gateway understands.
 *
 * ## What gets sent
 * Only **key VRP waypoints** are dispatched — not every intermediate A*
 * pathfinding step. Depot nodes (`type === 'depot'` or `alias === '__depot__'`)
 * are skipped because the robot starts and ends there automatically.
 *
 * ## Sequencing
 * Orders are sent one at a time with `await` so the Redis pub/sub channel
 * receives them in route order. A 200 ms gap between commands prevents the
 * robot_bridge from dropping messages under load.
 *
 * @param vehicleIndex  - Zero-based VRP vehicle index (0 = Vehicle 1).
 * @param vrpWaypoints  - Ordered node IDs straight from the VRP solver
 *                        (before A* expansion). e.g. `[1, 5, 15, 1]`.
 * @param nodes         - Full node list from the warehouse graph DB (for
 *                        ID → alias and type lookup).
 * @returns             Aggregated dispatch result with per-node log.
 * @throws              Error if no robot is mapped to the given vehicle index.
 */
export async function dispatchVehicleRoute(
  vehicleIndex: number,
  vrpWaypoints: number[],
  nodes: DBNode[],
): Promise<RouteDispatchResult> {
  // Look up the robot name for this vehicle slot
  const robotName = VEHICLE_ROBOT_MAP[vehicleIndex];
  if (!robotName) {
    throw new Error(
      `No robot is mapped to vehicle index ${vehicleIndex}. ` +
      `Add an entry to VEHICLE_ROBOT_MAP in fleetGateway.ts.`,
    );
  }

  // Build a fast lookup: nodeId → { alias, type, x, y }
  const nodeInfo = new Map<number, { alias: string; type: string; x: number; y: number }>(
    nodes.map(n => [n.id, { alias: n.alias ?? `Node ${n.id}`, type: n.type ?? '', x: n.x, y: n.y }]),
  );

  const log: string[] = [];
  let dispatched = 0;
  let skipped = 0;

  console.log(
    `[Fleet] Dispatching Vehicle ${vehicleIndex + 1} → ${robotName} ` +
    `(${vrpWaypoints.length} waypoints)`,
  );

  // ดึงค่า signal ปัจจุบันมาใช้ในลูปนี้
  const signal = dispatchAbortController.signal;

  for (const nodeId of vrpWaypoints) {
    if (signal.aborted) {
      log.push(`[System] Dispatch cancelled by operator.`);
      console.warn(`[Fleet] Dispatch for ${robotName} aborted.`);
      break;
    }
    while (isFleetPaused) {
      if (signal.aborted) {
        log.push(`[System] Dispatch cancelled by operator.`);
        console.warn(`[Fleet] Dispatch for ${robotName} aborted while paused.`);
        break;
      }
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, 500);
        signal.addEventListener(
          'abort',
          () => {
            clearTimeout(timer);
            resolve();
          },
          { once: true },
        );
      });
    }
    if (signal.aborted) {
      log.push(`[System] Dispatch cancelled by operator.`);
      console.warn(`[Fleet] Dispatch for ${robotName} aborted.`);
      break;
    }

    const info = nodeInfo.get(nodeId);
    if (!info) {
      skipped++;
      continue;
    }

    if (info.type === 'depot' || info.alias === '__depot__') {
      skipped++;
      continue;
    }

    try {
      await sendTravelOrder(robotName, info.alias, info.x, info.y);
      log.push(`✓ ${robotName} → ${info.alias}`);
      dispatched++;

      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, 2000);
        signal.addEventListener(
          'abort',
          () => {
            clearTimeout(timer);
            resolve();
          },
          { once: true },
        );
      });

    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      log.push(`✗ ${info.alias}: ${msg}`);
    }
  }

  console.log(
    `[Fleet] Dispatch complete: ${dispatched} sent, ${skipped} skipped`,
  );

  return { robotName, dispatched, skipped, log };
}

/**
 * Cancels all currently active vehicle dispatch sequences.
 * This will immediately break the dispatch loops and prevent further waypoints
 * from being sent to the robots.
 */
export const cancelAllDispatches = (): void => {
  dispatchAbortController.abort();
  // Reset the controller for future dispatches
  dispatchAbortController = new AbortController();
  isFleetPaused = false;
  const activeRobots = Array.from(new Set(Object.values(VEHICLE_ROBOT_MAP)));
  void Promise.allSettled(
    activeRobots.map((robotName) => sendRobotControlCommand(robotName, 'ESTOP')),
  );
  console.log('[Fleet Gateway] All active dispatches have been cancelled by user and ESTOP sent.');
};