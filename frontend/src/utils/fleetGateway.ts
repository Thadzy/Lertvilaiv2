/**
 * Fleet Gateway GraphQL Client
 * =============================
 * Communicates with `fleet_gateway_custom` (port 8080) through the Vite dev-server
 * reverse proxy configured at `/api/fleet` → `http://127.0.0.1:8080`.
 *
 * Responsibilities:
 * - Provide a typed wrapper around the `executePathOrder` GraphQL mutation.
 * - Maintain the authoritative mapping from VRP vehicle-index to physical robot name.
 * - Dispatch closed-loop batch path commands to the backend.
 */

import type { DBNode } from '../types/database';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const FLEET_GW_URL = '/api/fleet/graphql';
export let isFleetPaused = false;

/**
 * อัปเดตสถานะการหยุดชั่วคราวของระบบ Fleet
 * @param state - true เพื่อหยุด, false เพื่อรันต่อ
 */
export const setFleetPaused = (state: boolean): void => {
  isFleetPaused = state;

  // ส่งคำสั่งไปยังหุ่นยนต์ทุกตัวในวงเพื่อ PAUSE หรือ RESUME จริงๆ ที่ตัวหุ่นด้วย
  const activeRobots = Array.from(new Set(Object.values(VEHICLE_ROBOT_MAP)));
  const command = state ? 'PAUSE' : 'RESUME';

  void Promise.allSettled(
    activeRobots.map((robotName) => sendRobotControlCommand(robotName, command))
  );

  console.log(`[Fleet Gateway] Fleet global state set to: ${command}`);
};

export const VEHICLE_ROBOT_MAP: Record<number, string> = {
  0: 'FACOBOT',
} as const;

const getFallbackRobotName = (): string => {
  return VEHICLE_ROBOT_MAP[0] ?? Object.values(VEHICLE_ROBOT_MAP)[0] ?? 'FACOBOT';
};

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface JobOrderResult {
  success: boolean;
  message: string;
  job?: {
    uuid: string;
    status: string;
  };
}

export interface RobotControlResult {
  success: boolean;
  message: string;
}

export interface RouteDispatchResult {
  robotName: string;
  dispatched: number; // For batch, this will be 1 (one batch command sent)
  skipped: number;
  log: string[];
}

// ---------------------------------------------------------------------------
// GraphQL helper
// ---------------------------------------------------------------------------

async function gql<T = unknown>(
  query: string,
  variables?: Record<string, unknown>,
): Promise<T> {
  const res = await fetch(FLEET_GW_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ query, variables }),
    signal: AbortSignal.timeout(10_000),
  });

  if (!res.ok) {
    throw new Error(`Fleet Gateway returned HTTP ${res.status}`);
  }

  const body = await res.json();

  if (body.errors?.length) {
    throw new Error(`GraphQL error: ${body.errors[0].message}`);
  }

  return body.data as T;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Execute a closed-loop batch path command on a named robot.
 *
 * Translates to the new Fleet Gateway mutation:
 * ```graphql
 * mutation ExecutePathOrder($order: ExecutePathOrderInput!) {
 * executePathOrder(order: $order) { success message job { uuid status } }
 * }
 * ```
 *
 * @param robotName - Registered robot name (e.g. "FACOBOT").
 * @param graphId - The database graph ID (e.g. 1).
 * @param vrpPath - Array of node indices from VRP (e.g. [1, 62, 71, 1]).
 * @returns The mutation result.
 */
export async function executePathOrder(
  robotName: string,
  graphId: number,
  vrpPath: number[]
): Promise<JobOrderResult> {
  const data = await gql<{ executePathOrder: JobOrderResult }>(
    `mutation ExecutePathOrder($order: ExecutePathOrderInput!) {
       executePathOrder(order: $order) {
         success
         message
         job { uuid status }
       }
     }`,
    { order: { robotName, graphId, vrpPath } },
  );

  const result = data.executePathOrder;

  if (!result.success) {
    throw new Error(`executePathOrder rejected: ${result.message}`);
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

export let dispatchAbortController = new AbortController();

export const beginNewDispatchBatch = (): AbortSignal => {
  dispatchAbortController.abort();
  dispatchAbortController = new AbortController();
  return dispatchAbortController.signal;
};

/**
 * Dispatches a full VRP sequence to the backend as a single batch command.
 * * The backend service (fleet_gateway) will take this array, expand it into A* * coordinates via route_oracle, and manage the point-to-point movement using 
 * closed-loop distance checking.
 *
 * @param vehicleIndex - Zero-based VRP vehicle index.
 * @param graphId      - ID of the warehouse graph (e.g. 1).
 * @param vrpWaypoints - Ordered node IDs from the VRP solver (e.g. [1, 62, 71, 1]).
 * @returns            Aggregated dispatch result with per-node log.
 */
export async function dispatchVehicleRoute(
  vehicleIndex: number,
  graphId: number,
  vrpWaypoints: number[],
): Promise<RouteDispatchResult> {
  const robotName = VEHICLE_ROBOT_MAP[vehicleIndex] ?? getFallbackRobotName();
  const log: string[] = [];
  let dispatched = 0;

  console.log(
    `[Fleet] Batch Dispatching Vehicle ${vehicleIndex + 1} → ${robotName} ` +
    `(Graph: ${graphId}, Path: ${vrpWaypoints.join(' -> ')})`
  );

  if (!(vehicleIndex in VEHICLE_ROBOT_MAP)) {
    log.push(
      `[System] Vehicle ${vehicleIndex + 1} has no explicit mapping; using fallback robot ${robotName}.`,
    );
  }

  if (dispatchAbortController.signal.aborted) {
    log.push(`[System] Dispatch cancelled by operator before sending.`);
    return { robotName, dispatched: 0, skipped: vrpWaypoints.length, log };
  }

  try {
    // ─── Single Batch Execution Call ───────────────────────────────────────
    const result = await executePathOrder(robotName, graphId, vrpWaypoints);

    log.push(`✓ Batch command dispatched to ${robotName}. Backend handling execution.`);
    log.push(`Job Status: ${result.job?.status ?? 'UNKNOWN'}`);
    dispatched = 1;

  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    log.push(`✗ Batch Dispatch Error: ${msg}`);
  }

  return { robotName, dispatched, skipped: 0, log };
}

/**
 * Sends an ESTOP command to all active robots to immediately halt movement.
 */
export const cancelAllDispatches = (): void => {
  dispatchAbortController.abort();
  dispatchAbortController = new AbortController();

  const activeRobots = Array.from(new Set(Object.values(VEHICLE_ROBOT_MAP)));
  void Promise.allSettled(
    activeRobots.map((robotName) => sendRobotControlCommand(robotName, 'ESTOP')),
  );
  console.log('[Fleet Gateway] All active dispatches have been cancelled by user and ESTOP sent.');
};