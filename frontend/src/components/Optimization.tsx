import React, { useState, useCallback } from 'react';
import {
  Cpu, Play, Plus, ArrowRight, Loader2, AlertCircle, CheckCircle2,
  MapIcon, Trash2, X, Eye, Send
} from 'lucide-react';
import { supabase } from '../lib/supabaseClient';
import { localAStar, generateDistanceMatrix } from '../utils/solverUtils';
import { solveVRP } from '../utils/vrpApi';
import { type DBNode, type DBEdge } from '../types/database';
import RouteVisualizer from './RouteVisualizer';



// ---------------------------------------------------------------------------
// TYPE DEFINITIONS
// ---------------------------------------------------------------------------

/** A single pickup-delivery task in the queue. */
interface QueuedTask {
  id: number;
  pickup: string;
  delivery: string;
}

/** A route returned by the VRP solver. */
interface SolverRoute {
  vehicle_id: number;
  steps: { node_id: number }[];
  nodes?: number[];
  distance: number;
}

/** The complete solution object passed to RouteVisualizer. */
interface SolverSolution {
  feasible: boolean;
  total_distance: number;
  wall_time_ms: number;
  routes: SolverRoute[];
  summary: string;
}

interface OptimizationProps {
  graphId: number;
  onDispatch?: (expandedRoutes: number[][], vrpWaypoints: number[][], nodes: DBNode[]) => void;
}

// ---------------------------------------------------------------------------
// COMPONENT
// ---------------------------------------------------------------------------

/**
 * Optimization -- Unified Fleet Optimization panel.
 *
 * Provides a single Task Queue where users can:
 *   1. Queue multiple pickup-delivery pairs.
 *   2. Preview any single task via A* pathfinding (click the eye icon).
 *   3. Send the entire queue to the VRP solver via "Optimize Fleet".
 *   4. Choose the start point mode: Depot, Robot, or Custom.
 *
 * @param graphId - The warehouse graph ID to load nodes/edges from.
 */
const Optimization: React.FC<OptimizationProps> = ({ graphId, onDispatch }) => {



  // -- Map data (loaded once, cached) --
  const [mapData, setMapData] = useState<{ nodes: DBNode[]; edges: DBEdge[]; map_url?: string | null } | null>(null);

  // -- Start Point mode (Depot / Robot / Custom) --
  const [startMode, setStartMode] = useState<'depot' | 'robot' | 'custom'>('depot');
  const [customStartNodeId, setCustomStartNodeId] = useState<string>('');

  // -- Task Queue --
  const [taskQueue, setTaskQueue] = useState<QueuedTask[]>([]);
  const [nextTaskId, setNextTaskId] = useState(1);
  const [newPickup, setNewPickup] = useState<string>('');
  const [newDelivery, setNewDelivery] = useState<string>('');

  // -- Fleet config --
  const [vehicleCount, setVehicleCount] = useState<number>(2);
  const [vehicleCapacity, setVehicleCapacity] = useState<number>(10);

  // -- Solver state --
  const [isSolving, setIsSolving] = useState(false);
  const [vrpSolution, setVrpSolution] = useState<SolverSolution | null>(null);
  const [vrpRawPaths, setVrpRawPaths] = useState<number[][] | null>(null);
  const [vrpError, setVrpError] = useState<string | null>(null);
  const [showVrpVisualizer, setShowVrpVisualizer] = useState(false);

  // -- A* Preview state --
  const [previewSolution, setPreviewSolution] = useState<SolverSolution | null>(null);
  const [showPreviewVisualizer, setShowPreviewVisualizer] = useState(false);
  const [previewingTaskId, setPreviewingTaskId] = useState<number | null>(null);

  // -- Node Selection Mode --
  const [selectingMode, setSelectingMode] = useState<'pickup' | 'delivery' | null>(null);

  // -----------------------------------------------------------------------
  // DATA LOADING
  // -----------------------------------------------------------------------

  /**
   * Loads graph nodes and edges from Supabase. Caches after first load.
   * @returns The map data object or null on failure.
   */
  const loadMapData = useCallback(async (): Promise<{ nodes: DBNode[]; edges: DBEdge[]; map_url?: string | null } | null> => {
    if (mapData) return mapData;
    if (!graphId) return null;
    try {
      const { data: nodeData } = await supabase
        .from('wh_nodes_view').select('*').eq('graph_id', graphId);
      const { data: edgeData } = await supabase
        .from('wh_edges').select('*').eq('graph_id', graphId);
      const { data: graphRecord } = await supabase
        .from('wh_graphs').select('map_url').eq('id', graphId).single();
        
      if (nodeData && edgeData) {
        const loaded = { 
          nodes: nodeData as DBNode[], 
          edges: edgeData as DBEdge[],
          map_url: graphRecord?.map_url || null
        };
        setMapData(loaded);
        return loaded;
      }
    } catch (e) {
      console.error('[Optimization] Map fetch error:', e);
    }
    return null;
  }, [graphId, mapData]);

  // -----------------------------------------------------------------------
  // START NODE RESOLUTION
  // -----------------------------------------------------------------------

  /**
   * Resolves the start node ID based on the current startMode.
   * - depot: finds the first node with type "depot".
   * - robot: same as depot (robot assumed at depot when idle).
   * - custom: uses the user-selected customStartNodeId.
   *
   * @param nodes - Array of DBNode from the loaded map.
   * @returns The resolved node ID, or null if none found.
   */
  const resolveStartNode = (nodes: DBNode[]): number | null => {
    if (startMode === 'custom') {
      return customStartNodeId ? parseInt(customStartNodeId) : null;
    }
    // Both 'depot' and 'robot' resolve to the depot node
    const depot = nodes.find(n => n.type === 'depot');
    return depot ? depot.id : (nodes[0]?.id ?? null);
  };

  /**
   * Handles node selection from the map picker.
   */
  const handleNodeSelect = (nodeId: number) => {
    if (selectingMode === 'pickup') setNewPickup(String(nodeId));
    if (selectingMode === 'delivery') setNewDelivery(String(nodeId));
    setSelectingMode(null);
  };

  // -----------------------------------------------------------------------
  // TASK QUEUE MANAGEMENT
  // -----------------------------------------------------------------------

  /**
   * Adds a new pickup-delivery pair to the task queue.
   * Validates that both fields are set and not identical.
   */
  const handleAddTask = () => {
    if (!newPickup || !newDelivery) {
      alert('Select both a pickup and a delivery node.');
      return;
    }
    if (newPickup === newDelivery) {
      alert('Pickup and delivery must be different nodes.');
      return;
    }
    setTaskQueue(prev => [...prev, { id: nextTaskId, pickup: newPickup, delivery: newDelivery }]);
    setNextTaskId(prev => prev + 1);
    setNewPickup('');
    setNewDelivery('');
  };

  /**
   * Removes a single task from the queue by its index.
   * @param index - The array index of the task to remove.
   */
  const handleRemoveTask = (index: number) => {
    setTaskQueue(prev => prev.filter((_, i) => i !== index));
  };

  /** Clears all tasks from the queue and resets solver results. */
  const handleClearQueue = () => {
    setTaskQueue([]);
    setVrpSolution(null);
    setVrpError(null);
    setNextTaskId(1);
  };

  // -----------------------------------------------------------------------
  // A* PREVIEW (single task)
  // -----------------------------------------------------------------------

  /**
   * Runs A* pathfinding for a single queued task and opens the map preview.
   * The path goes from the resolved start node to each task's pickup, then delivery.
   *
   * @param task - The queued task to preview.
   */
  const handlePreviewTask = async (task: QueuedTask) => {
    const map = mapData || await loadMapData();
    if (!map) { alert('Cannot load map data.'); return; }

    const startId = resolveStartNode(map.nodes);
    if (!startId) { alert('Please select a valid start node.'); return; }

    const pickupId = parseInt(task.pickup);
    const deliveryId = parseInt(task.delivery);

    // Build path: Start -> Pickup -> Delivery
    const pathToPickup = localAStar(startId, pickupId, map.nodes, map.edges);
    const pathToDelivery = localAStar(pickupId, deliveryId, map.nodes, map.edges);

    if (!pathToPickup || !pathToDelivery) {
      alert('No path found. The nodes may be unreachable from the start point.');
      return;
    }

    // Merge paths (avoid duplicating the pickup node)
    const fullPath = [...pathToPickup, ...pathToDelivery.slice(1)];

    console.log(`[Preview] Task #${task.id}: ${fullPath.join(' -> ')}`);

    setPreviewSolution({
      feasible: true,
      total_distance: 0,
      wall_time_ms: 0,
      summary: `Preview: Task #${task.id} (${fullPath.length} nodes)`,
      routes: [{
        vehicle_id: 0,
        steps: fullPath.map((id: number) => ({ node_id: id })),
        distance: 0,
      }],
    });
    setPreviewingTaskId(task.id);
    setShowPreviewVisualizer(true);
  };

  // -----------------------------------------------------------------------
  // VRP SOLVER
  // -----------------------------------------------------------------------

  /**
   * Sends the entire task queue to the VRP solver backend.
   * Builds the distance matrix locally, maps node IDs to matrix indices,
   * and calls the dual-server solveVRP function.
   */
  const handleOptimize = async () => {
    if (taskQueue.length === 0) {
      alert('Add at least one task to the queue before optimizing.');
      return;
    }

    setIsSolving(true);
    setVrpError(null);
    setVrpSolution(null);

    try {
      const map = await loadMapData();

      // Build distance matrix for the Python server fallback
      let distMatrix: number[][] | undefined;
      if (map) {
        distMatrix = generateDistanceMatrix(map.nodes, map.edges);
      }

      // Resolve start node for each vehicle (all vehicles start at the same point)
      const startNodeId = map ? resolveStartNode(map.nodes) : null;
      const robotLocations = startNodeId
        ? Array(vehicleCount).fill(startNodeId)
        : undefined;

      const { paths, server } = await solveVRP(
        {
          graph_id: graphId,
          num_vehicles: vehicleCount,
          pickups_deliveries: taskQueue.map(t => ({
            id: t.id,
            pickup: parseInt(t.pickup),
            delivery: parseInt(t.delivery),
          })),
          robot_locations: robotLocations,
          vehicle_capacity: vehicleCapacity,
        },
        map?.nodes || [],
        distMatrix,
      );

      // Convert paths (number[][]) into the SolverSolution format
      const routes: SolverRoute[] = paths.map((path, i) => {
        let fullPath: number[] = [];
        if (map && path.length > 0) {
          fullPath.push(path[0]); // Start node
          for (let j = 0; j < path.length - 1; j++) {
            const startId = path[j];
            const endId = path[j + 1];
            if (startId === endId) continue; // Skip if same node

            const segment = localAStar(startId, endId, map.nodes, map.edges);
            if (segment && segment.length > 1) {
              // Append segment, skipping the first node to avoid duplicates
              fullPath.push(...segment.slice(1));
            } else {
              // Fallback if A* fails
              fullPath.push(endId);
            }
          }
        } else {
          fullPath = path;
        }

        return {
          vehicle_id: i + 1,
          steps: fullPath.map(nodeId => ({ node_id: nodeId })),
          nodes: fullPath, // Keep both for compatibility
          distance: 0,
        };
      });

      const sol: SolverSolution = {
        feasible: true,
        total_distance: 0,
        wall_time_ms: 0,
        summary: `${routes.length} vehicles, ${taskQueue.length} tasks (via ${server} server)`,
        routes,
      };

      setVrpSolution(sol);
      setVrpRawPaths(paths);
      console.log(`[VRP] Solution: ${routes.length} routes via ${server} server`);

    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : 'Unknown error';
      console.error('[VRP] Error:', msg);
      setVrpError(msg);
    } finally {
      setIsSolving(false);
    }
  };

  // -----------------------------------------------------------------------
  // HELPERS
  // -----------------------------------------------------------------------

  /** All loaded node options for the dropdown selectors. */
  const nodeOptions = mapData?.nodes || [];

  /**
   * Looks up a node alias by its string ID.
   * @param id - The node ID as a string.
   * @returns The alias or a fallback label.
   */
  const getNodeLabel = (id: string): string => {
    const node = nodeOptions.find(n => String(n.id) === id);
    return node?.alias || `Node ${id}`;
  };

  // -----------------------------------------------------------------------
  // RENDER
  // -----------------------------------------------------------------------

  return (
    <div className="flex h-full w-full bg-gray-50 dark:bg-[#09090b] text-gray-900 dark:text-white transition-colors p-4 sm:p-6 gap-6 relative overflow-hidden">
      
      {/* ================================================================= */}
      {/* LEFT COLUMN: CONTROLS & QUEUE                                     */}
      {/* ================================================================= */}
      <div className="w-full lg:w-[450px] flex flex-col gap-5 overflow-y-auto pr-2 pb-10 custom-scrollbar z-10">
        
        {/* -- Configuration Card -- */}
        <div className="bg-white dark:bg-[#121214] border border-gray-200 dark:border-white/5 rounded-2xl shadow-sm flex flex-col shrink-0 overflow-hidden">
          <div className="bg-gradient-to-r from-blue-50/50 to-indigo-50/50 dark:from-white/5 dark:to-transparent px-5 py-3 border-b border-gray-100 dark:border-white/5">
            <h2 className="text-sm font-bold flex items-center gap-2">
              <Cpu className="text-blue-500" size={18} /> Optimization Settings
            </h2>
          </div>
          
          <div className="p-5 space-y-5">
            {/* Start Point */}
            <div>
              <label className="text-[10px] text-gray-500 dark:text-gray-400 font-bold uppercase block mb-2">
                Start Point Designation
              </label>
              <div className="flex gap-2 text-xs">
                {(['depot', 'robot', 'custom'] as const).map(mode => (
                  <button
                    key={mode}
                    onClick={() => setStartMode(mode)}
                    className={`flex-1 py-1.5 rounded-lg border font-bold capitalize transition-all ${startMode === mode
                      ? 'bg-blue-50 border-blue-300 text-blue-700 shadow-sm dark:bg-blue-500/20 dark:border-blue-500/50 dark:text-blue-300'
                      : 'bg-gray-50 dark:bg-white/5 border-gray-200 dark:border-white/10 text-gray-500 dark:text-gray-400 hover:border-slate-300'
                      }`}
                  >
                    {mode === 'depot' ? 'Depot' : mode === 'robot' ? 'Robot' : 'Custom'}
                  </button>
                ))}
              </div>
              {startMode === 'custom' && (
                <select
                  className="w-full text-xs p-2.5 mt-2 border border-gray-200 dark:border-white/10 rounded-lg bg-gray-50 dark:bg-white/5 focus:ring-2 focus:ring-blue-200 focus:border-blue-400 outline-none"
                  value={customStartNodeId}
                  onChange={e => setCustomStartNodeId(e.target.value)}
                >
                  <option value="">Select start node...</option>
                  {nodeOptions.map(n => (
                    <option key={n.id} value={n.id}>
                      {n.alias || `Node ${n.id}`} ({n.type})
                    </option>
                  ))}
                </select>
              )}
            </div>

            {/* Vehicle Count */}
            <div>
              <label className="text-[10px] text-gray-500 dark:text-gray-400 font-bold uppercase block mb-2">
                Available Fleet Vehicles
              </label>
              <input
                type="number" min="1" max="10" value={vehicleCount}
                onChange={e => setVehicleCount(Math.max(1, parseInt(e.target.value) || 1))}
                className="w-full text-sm p-2 border border-gray-200 dark:border-white/10 rounded-lg font-mono font-bold bg-gray-50 dark:bg-white/5"
              />
            </div>

            {/* Vehicle Capacity */}
            <div>
              <label className="text-[10px] text-gray-500 dark:text-gray-400 font-bold uppercase block mb-2">
                Max Tasks per Vehicle
              </label>
              <input
                type="number" min="1" max="100" value={vehicleCapacity}
                onChange={e => setVehicleCapacity(Math.max(1, parseInt(e.target.value) || 1))}
                className="w-full text-sm p-2 border border-gray-200 dark:border-white/10 rounded-lg font-mono font-bold bg-gray-50 dark:bg-white/5"
              />
            </div>
          </div>
        </div>

        {/* -- Task Queue Card -- */}
        <div className="bg-white dark:bg-[#121214] border border-gray-200 dark:border-white/5 rounded-2xl shadow-sm flex flex-col shrink-0 flex-1 min-h-[400px] overflow-hidden">
          <div className="bg-gray-50 dark:bg-white/5 px-5 py-3 border-b border-gray-100 dark:border-white/5 flex items-center justify-between">
            <h2 className="text-sm font-bold flex items-center gap-2">
              <MapIcon className="text-purple-500" size={18} /> Task Queue
              <span className="ml-2 bg-purple-100 text-purple-700 dark:bg-purple-500/20 dark:text-purple-300 text-[10px] px-2 py-0.5 rounded-full font-mono">
                {taskQueue.length} TASKS
              </span>
            </h2>
            {taskQueue.length > 0 && (
              <button
                onClick={handleClearQueue}
                className="text-[10px] text-red-500 hover:text-red-700 bg-red-50 hover:bg-red-100 dark:bg-red-500/10 dark:hover:bg-red-500/20 px-2 py-1 rounded font-bold flex items-center gap-1 transition-colors"
              >
                <Trash2 size={10} /> Clear All
              </button>
            )}
          </div>

          <div className="flex-1 p-5 flex flex-col gap-4 overflow-y-auto">
            {/* Task Add Fields */}
            <div className="flex gap-2 items-end bg-blue-50/50 dark:bg-blue-900/10 p-3 rounded-xl border border-blue-100 dark:border-blue-900/30">
              <div className="flex-1">
                <label className="text-[9px] text-blue-600 dark:text-blue-400 font-bold uppercase block mb-1">Pickup</label>
                <div className="flex gap-1">
                  <select
                    className="w-full text-xs p-2 border border-white dark:border-white/10 rounded-lg shadow-sm bg-white dark:bg-[#121214]"
                    value={newPickup}
                    onChange={e => setNewPickup(e.target.value)}
                  >
                    <option value="">From...</option>
                    {nodeOptions.map(n => <option key={n.id} value={n.id}>{n.alias || `Node ${n.id}`}</option>)}
                  </select>
                  <button
                    onClick={() => { loadMapData(); setSelectingMode('pickup'); }}
                    className="p-2 bg-white dark:bg-[#121214] border border-gray-200 dark:border-white/10 hover:border-blue-300 rounded-lg text-blue-600 shadow-sm"
                    title="Select from map"
                  >
                    <MapIcon size={16} />
                  </button>
                </div>
              </div>
              <div className="flex-1">
                <label className="text-[9px] text-blue-600 dark:text-blue-400 font-bold uppercase block mb-1">Delivery</label>
                <div className="flex gap-1">
                  <select
                    className="w-full text-xs p-2 border border-white dark:border-white/10 rounded-lg shadow-sm bg-white dark:bg-[#121214]"
                    value={newDelivery}
                    onChange={e => setNewDelivery(e.target.value)}
                  >
                    <option value="">To...</option>
                    {nodeOptions.map(n => <option key={n.id} value={n.id}>{n.alias || `Node ${n.id}`}</option>)}
                  </select>
                  <button
                    onClick={() => { loadMapData(); setSelectingMode('delivery'); }}
                    className="p-2 bg-white dark:bg-[#121214] border border-gray-200 dark:border-white/10 hover:border-blue-300 rounded-lg text-blue-600 shadow-sm"
                    title="Select from map"
                  >
                    <MapIcon size={16} />
                  </button>
                </div>
              </div>
              <button
                onClick={handleAddTask}
                className="p-2 bg-blue-600 text-white hover:bg-blue-700 shadow-sm rounded-lg transition-colors"
                title="Add task"
              >
                <Plus size={16} />
              </button>
            </div>

            {/* Active Tasks List */}
            <div className="space-y-2">
              {taskQueue.length > 0 ? (
                taskQueue.map((task, i) => (
                  <div
                    key={task.id}
                    className="flex items-center gap-3 bg-white dark:bg-white/5 border border-gray-100 dark:border-white/5 rounded-xl px-4 py-3 text-xs group hover:border-blue-200 dark:hover:border-blue-500/30 hover:shadow-sm transition-all"
                  >
                    <span className="font-mono text-gray-400 dark:text-gray-500 w-5">#{task.id}</span>
                    <span className="font-bold text-green-700 dark:text-green-500">{getNodeLabel(task.pickup)}</span>
                    <ArrowRight size={12} className="text-gray-300 dark:text-gray-600" />
                    <span className="font-bold text-red-700 dark:text-red-500">{getNodeLabel(task.delivery)}</span>
                    
                    <div className="ml-auto flex items-center gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
                      <button
                        onClick={() => handlePreviewTask(task)}
                        className={`p-1.5 rounded-md transition-colors ${previewingTaskId === task.id ? 'bg-blue-100 text-blue-700 dark:bg-blue-600/30 dark:text-blue-300' : 'text-blue-500 hover:bg-blue-50 dark:hover:bg-blue-500/10'}`}
                        title="Preview"
                      >
                        <Eye size={14} />
                      </button>
                      <button
                        onClick={() => handleRemoveTask(i)}
                        className="p-1.5 rounded-md text-red-500 hover:bg-red-50 dark:hover:bg-red-500/10"
                        title="Remove"
                      >
                        <X size={14} />
                      </button>
                    </div>
                  </div>
                ))
              ) : (
                <div className="text-center text-xs text-gray-400 py-8 italic grayscale opacity-70 border border-dashed border-gray-200 dark:border-white/10 rounded-xl">
                  Your task queue is empty. Use the form above.
                </div>
              )}
            </div>
          </div>
          
          {/* Action Footer */}
          <div className="p-5 bg-gray-50/50 dark:bg-white/5 border-t border-gray-100 dark:border-white/5 space-y-3">
            <button
              onClick={handleOptimize}
              disabled={isSolving || taskQueue.length === 0}
              className="w-full py-3.5 bg-gradient-to-r from-blue-600 to-indigo-600 text-white text-sm font-bold rounded-xl hover:from-blue-700 hover:to-indigo-700 transition-all active:scale-[0.98] flex items-center justify-center gap-2 shadow-lg shadow-blue-500/25 disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {isSolving ? (
                <><Loader2 size={18} className="animate-spin" /> GENERATING ROUTES...</>
              ) : (
                <><Play size={18} fill="white" /> OPTIMIZE FLEET ROUTES</>
              )}
            </button>

            {/* Status Messages */}
            {vrpError && (
              <div className={`flex items-start gap-2 p-3 border rounded-xl text-xs ${vrpError.toLowerCase().includes('infeasible') 
                  ? 'bg-amber-50 border-amber-200 text-amber-800 dark:bg-amber-500/10 dark:border-amber-500/20 dark:text-amber-300' 
                  : 'bg-red-50 border-red-200 text-red-800 dark:bg-red-500/10 dark:border-red-500/20 dark:text-red-300'}`}>
                <AlertCircle size={16} className="mt-0.5 shrink-0" />
                <div>
                  <p className="font-bold tracking-tight">Optimization Error</p>
                  <p className="mt-0.5 opacity-90">{vrpError}</p>
                </div>
              </div>
            )}

            {vrpSolution && (
              <div className="p-4 bg-green-50 border border-green-200 dark:bg-green-500/10 dark:border-green-500/20 rounded-xl">
                <div className="flex items-center justify-between mb-3">
                  <div className="flex items-center gap-2">
                    <CheckCircle2 size={18} className="text-green-600 dark:text-green-400" />
                    <span className="text-sm font-bold text-green-800 dark:text-green-300">Solution Ready</span>
                  </div>
                  <span className="text-xs font-mono font-bold text-green-600 bg-green-100 dark:bg-green-500/20 px-2 py-0.5 rounded">
                    {vrpSolution.routes.length} Vehicles
                  </span>
                </div>
                
                <div className="grid grid-cols-2 gap-2">
                  <button
                    onClick={async () => {
                      await loadMapData();
                      setShowVrpVisualizer(true);
                    }}
                    className="py-2.5 bg-white dark:bg-white/5 border border-green-200 dark:border-green-500/30 text-green-700 dark:text-green-400 text-xs font-bold rounded-lg hover:bg-green-100 dark:hover:bg-green-500/20 transition-colors flex items-center justify-center gap-1.5 shadow-sm"
                  >
                    <MapIcon size={14} /> VIEW MAP
                  </button>
                  {onDispatch && (
                    <button
                      onClick={() => {
                        const expandedRoutes = vrpSolution!.routes.map(r => r.nodes || r.steps.map(s => s.node_id));
                        onDispatch(expandedRoutes, vrpRawPaths ?? expandedRoutes, mapData?.nodes ?? []);
                      }}
                      className="py-2.5 bg-green-600 hover:bg-green-700 text-white text-xs font-bold rounded-lg transition-colors flex items-center justify-center gap-1.5 shadow-md shadow-green-500/20"
                    >
                      <Send size={14} /> DISPATCH
                    </button>
                  )}
                </div>
              </div>
            )}
          </div>
        </div>
      </div>

      {/* ================================================================= */}
      {/* RIGHT COLUMN: PREVIEW AREA                                        */}
      {/* ================================================================= */}
      <div className="hidden lg:flex flex-1 bg-white dark:bg-[#121214] border border-gray-200 dark:border-white/5 rounded-2xl shadow-sm overflow-hidden flex-col relative justify-center items-center z-0">
        <div className="absolute inset-0 opacity-[0.03] dark:opacity-[0.02]" style={{ backgroundImage: 'radial-gradient(circle at 2px 2px, black 1px, transparent 0)', backgroundSize: '24px 24px' }} />
        
        {mapData?.nodes && mapData.nodes.length > 0 ? (
          <RouteVisualizer
            isOpen={true}
            inline={true}
            map_url={mapData?.map_url}
            dbNodes={mapData.nodes}
            dbEdges={mapData.edges}
            solution={null}
            onClose={() => {}}
          />
        ) : (
          <div className="text-center z-10 p-8">
             <div className="w-16 h-16 bg-gray-100 dark:bg-white/5 rounded-full flex items-center justify-center mx-auto mb-4 animate-[pulse_3s_ease-in-out_infinite]">
              <MapIcon size={24} className="text-gray-400" />
            </div>
            <button
              onClick={loadMapData}
              className="text-sm font-bold text-blue-600 hover:text-blue-800 hover:underline"
            >
              Load Graph Layout Data
            </button>
            <p className="text-xs text-gray-500 dark:text-gray-400 mt-2">Required before queueing tasks</p>
          </div>
        )}
      </div>

      {/* ================================================================= */}
      {/* MAP SELECTOR (for picking start/end nodes)                        */}
      {/* ================================================================= */}
      <RouteVisualizer
        isOpen={selectingMode !== null}
        onClose={() => setSelectingMode(null)}
        solution={null}
        dbNodes={mapData?.nodes || []}
        dbEdges={mapData?.edges || []}
        onNodeClick={handleNodeSelect}
        title={`Select ${selectingMode === 'pickup' ? 'Pickup' : 'Delivery'} Node`}
        instruction="Click a node on the map to select it"
      />

      {/* ================================================================= */}
      {/* A* PREVIEW VISUALIZER (single task preview)                       */}
      {/* ================================================================= */}
      <RouteVisualizer
        isOpen={showPreviewVisualizer}
        onClose={() => {
          setShowPreviewVisualizer(false);
          setPreviewSolution(null);
          setPreviewingTaskId(null);
        }}
        solution={previewSolution}
        dbNodes={mapData?.nodes || []}
        dbEdges={mapData?.edges || []}
      />

      {/* ================================================================= */}
      {/* VRP SOLUTION VISUALIZER (multi-vehicle routes)                    */}
      {/* ================================================================= */}
      <RouteVisualizer
        isOpen={showVrpVisualizer}
        onClose={() => setShowVrpVisualizer(false)}
        solution={vrpSolution}
        dbNodes={mapData?.nodes || []}
        dbEdges={mapData?.edges || []}
      />
    </div>
  );
};

export default Optimization;