import { type DBNode } from '../types/database';

/**
 * VRP API Client
 *
 * Communicates exclusively with the C++ VRP server proxied via Vite at /api/cpp-vrp.
 * The C++ server (Crow + OR-Tools, port 18080) handles cost-matrix computation
 * internally using the warehouse graph stored in PostgreSQL.
 *
 * Python VRP fallback has been removed — all routing must go through the C++ server.
 */

/**
 * Proxy paths (configured in vite.config.ts).
 *   /api/fleet  → fleet_gateway (port 8080) — validated VRP + decomposition
 *   /api/cpp-vrp → C++ OR-Tools server (port 18080) — raw solver (legacy)
 */
const FLEET_GATEWAY_URL = '/api/fleet';
const CPP_VRP_URL = '/api/cpp-vrp';

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/**
 * Request payload sent to the C++ VRP solver.
 *
 * @property graph_id           - ID of the warehouse graph in PostgreSQL.
 * @property num_vehicles       - Number of robots available for assignment.
 * @property pickups_deliveries - Array of pickup/delivery node ID pairs.
 * @property robot_locations    - Optional array of starting node IDs per robot.
 * @property vehicle_capacity   - Optional maximum number of tasks per robot.
 */
export interface VrpRequest {
    graph_id: number;
    num_vehicles: number;
    pickups_deliveries: { id?: number; pickup: number; delivery: number }[];
    robot_locations?: number[];
    vehicle_capacity?: number;
}

/** Raw response envelope returned by the C++ VRP server. */
interface CppVrpResponse {
    status: 'success' | 'error';
    data?: { paths: number[][] };
    error?: { type: string; message: string };
}

/** Response envelope from the fleet_gateway /vrp/solve endpoint. */
interface GatewayVrpResponse {
    success: boolean;
    paths?: number[][];
    decomposed?: boolean;
    error_code?: string;
    error_message?: string;
}

/** Human-readable labels for fleet_gateway error codes. */
const VRP_ERROR_LABELS: Record<string, string> = {
    NO_SOLUTION:        'No feasible route found',
    INCOMPLETE_COSTMAP: 'Graph not fully connected',
    OVERCAPACITY:       'Fleet overcapacity',
    UNREACHABLE_NODE:   'Unreachable node in graph',
    SERVER_UNAVAILABLE: 'VRP server unavailable',
    VALIDATION_ERROR:   'Invalid request',
    UNKNOWN:            'Solver error',
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/**
 * Submit a VRP solve request through the fleet_gateway `/vrp/solve` endpoint.
 *
 * The fleet_gateway provides:
 * - Pre-flight validation (self-loops, overcapacity, empty queues).
 * - Structured `error_code` + `error_message` on failure.
 * - Automatic task decomposition when duplicate pickup nodes cause OR-Tools
 *   to fail with "Failed to find a solution".
 *
 * @param req - The VRP request parameters.
 * @returns   A 2-D array where each inner array is the ordered node IDs for one vehicle.
 * @throws    Error with a human-readable message on any failure.
 */
async function solveViaGateway(req: VrpRequest): Promise<number[][]> {
    const body = {
        graph_id: req.graph_id,
        num_vehicles: req.num_vehicles,
        pickups_deliveries: req.pickups_deliveries.map(pd => ({
            task_id: pd.id ?? null,
            pickup: pd.pickup,
            delivery: pd.delivery,
        })),
        robot_locations: req.robot_locations ?? null,
        vehicle_capacity: req.vehicle_capacity ?? null,
    };

    console.log('[VRP] Request payload (via fleet_gateway):', JSON.stringify(body, null, 2));

    const res = await fetch(`${FLEET_GATEWAY_URL}/vrp/solve`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(35000),
    });

    // Read raw text first so we can log it before attempting JSON parse
    const rawText = await res.text();
    console.log(`[VRP] fleet_gateway HTTP ${res.status} raw response:`, rawText);

    let json: GatewayVrpResponse & { detail?: unknown };
    try {
        json = JSON.parse(rawText);
    } catch {
        throw new Error(
            `fleet_gateway returned non-JSON response (HTTP ${res.status}): ${rawText.slice(0, 200)}`
        );
    }

    if (!json.success || !json.paths) {
        // Handle FastAPI native validation errors: {"detail": [{...}]}
        if (json.detail !== undefined) {
            const detail = Array.isArray(json.detail)
                ? json.detail.map((d: any) => `${d.loc?.join('.')}: ${d.msg}`).join('; ')
                : String(json.detail);
            throw new Error(`[Validation Error] ${detail}`);
        }
        const label = VRP_ERROR_LABELS[json.error_code ?? ''] ?? json.error_code ?? 'Error';
        throw new Error(`[${label}] ${json.error_message ?? `HTTP ${res.status} — see console for raw response`}`);
    }

    if (json.decomposed) {
        console.log('[VRP] Solution assembled via task decomposition (duplicate pickup nodes).');
    }

    return json.paths;
}

/**
 * Submit a VRP solve request directly to the C++ OR-Tools server (legacy path).
 *
 * Used only as a fallback when the fleet_gateway is unreachable.
 * Prefer `solveViaGateway` for validated, production requests.
 *
 * @param req - The VRP request parameters.
 * @returns   A 2-D array where each inner array is the ordered node IDs for one vehicle.
 * @throws    Error if the server returns an error status or an unexpected response shape.
 */
async function solveCppDirect(req: VrpRequest): Promise<number[][]> {
    const formData = new URLSearchParams();
    formData.append('graph_id', String(req.graph_id));
    formData.append('num_vehicles', String(req.num_vehicles));

    const pdArray = req.pickups_deliveries.map(pd => [pd.pickup, pd.delivery]);
    formData.append('pickups_deliveries', JSON.stringify(pdArray));

    if (req.robot_locations && req.robot_locations.length > 0) {
        formData.append('robot_locations', JSON.stringify(req.robot_locations));
    }
    if (req.vehicle_capacity && req.vehicle_capacity > 0) {
        formData.append('vehicle_capacity', String(req.vehicle_capacity));
    }

    console.log('[VRP] Fallback: sending direct to C++ server');

    const res = await fetch(`${CPP_VRP_URL}/solve_id`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: formData,
        signal: AbortSignal.timeout(30000),
    });

    if (!res.ok) {
        const text = await res.text();
        throw new Error(`C++ VRP server HTTP ${res.status}: ${text}`);
    }

    const json: CppVrpResponse = await res.json();

    if (json.status === 'error' || !json.data) {
        throw new Error(json.error?.message ?? 'C++ VRP solver returned an error with no message');
    }

    return json.data.paths;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Solve a Vehicle Routing Problem using the C++ VRP server.
 *
 * This is the single entry point for all route-optimisation calls in the
 * frontend. If the C++ server is unreachable or returns an error the
 * exception is propagated to the caller — there is no silent fallback.
 *
 * The `dbNodes` and `distanceMatrix` parameters are accepted for API
 * compatibility but are not used; the C++ server derives costs from the DB.
 *
 * @param req            - VRP problem definition (graph, vehicles, tasks).
 * @param _dbNodes       - Unused. Kept for call-site compatibility.
 * @param _distanceMatrix - Unused. Kept for call-site compatibility.
 * @returns An object containing the per-vehicle `paths` (node ID arrays)
 *          and `server: 'cpp'` indicating which backend was used.
 * @throws  Error if the C++ server is unavailable or returns no solution.
 */
/**
 * Solve a Vehicle Routing Problem.
 *
 * Routes the request through the fleet_gateway `/vrp/solve` endpoint (which
 * provides pre-validation and task decomposition).  Falls back to the C++
 * server directly only when the fleet_gateway is unreachable.
 *
 * @param req             - VRP problem definition (graph, vehicles, tasks).
 * @param _dbNodes        - Unused. Kept for call-site compatibility.
 * @param _distanceMatrix - Unused. Kept for call-site compatibility.
 * @returns An object containing the per-vehicle `paths` (node ID arrays)
 *          and `server` indicating which backend handled the request.
 * @throws  Error with a human-readable message if both backends fail.
 */
export async function solveVRP(
    req: VrpRequest,
    _dbNodes?: DBNode[],
    _distanceMatrix?: number[][],
): Promise<{ paths: number[][]; server: 'gateway' | 'cpp' }> {
    console.log('[VRP] Submitting solve request via fleet_gateway...');

    // Primary: fleet_gateway (validated, with decomposition fallback)
    try {
        const paths = await solveViaGateway(req);
        console.log(`[VRP] fleet_gateway returned ${paths.length} route(s)`);
        return { paths, server: 'gateway' };
    } catch (gatewayErr) {
        const msg = gatewayErr instanceof Error ? gatewayErr.message : String(gatewayErr);

        // If it's a known solver/validation error (not a connectivity issue),
        // surface it directly to the user without attempting the fallback.
        const isConnectivityError = msg.includes('unavailable') || msg.includes('fetch');
        if (!isConnectivityError) {
            throw gatewayErr;
        }

        console.warn('[VRP] fleet_gateway unreachable, falling back to direct C++ server:', msg);
    }

    // Fallback: direct C++ server (no validation, no decomposition)
    const paths = await solveCppDirect(req);
    console.log(`[VRP] C++ server (fallback) returned ${paths.length} route(s)`);
    return { paths, server: 'cpp' };
}

/**
 * Check whether the C++ VRP server is reachable via its /health endpoint.
 *
 * The `python` field is always `false` as the Python server has been removed.
 *
 * @returns `{ cpp: boolean; python: false }`
 */
export async function checkVrpServers(): Promise<{ cpp: boolean; python: false }> {
    let cpp = false;
    try {
        const res = await fetch(`${CPP_VRP_URL}/health`, {
            signal: AbortSignal.timeout(2000),
        });
        cpp = res.ok;
    } catch {
        cpp = false;
    }
    return { cpp, python: false };
}
