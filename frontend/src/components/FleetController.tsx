/**
 * Fleet Controller - Production-Grade Robot Fleet Visualization
 * ==============================================================
 *
 * This component provides real-time visualization of the robot fleet
 * on the warehouse map. It uses React Flow for the interactive canvas
 * and connects to the Fleet Gateway via MQTT.
 *
 * Performance Optimizations:
 * - Memoized node types and components to prevent re-renders
 * - Batched robot position updates (via useFleetSocket)
 * - Stable callbacks with useCallback to prevent child re-subscriptions
 *
 * @author WCS Team
 * @version 2.1.0 (Added Fleet Table)
 */

import React, { useEffect, useState, useCallback, useMemo, memo, useRef } from "react";
import ReactFlow, {
  Background,
  Controls,
  MiniMap,
  useNodesState,
  useEdgesState,
  useReactFlow,
  useStore,
  type Node,
  type Edge,
  Panel,
  BackgroundVariant,
  type NodeProps,
  Handle,
  Position,
  MarkerType,
} from "reactflow";
import "reactflow/dist/style.css";
import {
  Truck,
  PauseCircle,
  PlayCircle,
  AlertOctagon,
  Battery,
  Wifi,
  Activity,
  WifiOff,
  RefreshCw,
  Map as MapIcon,
  ChevronsRight,
  Terminal,
} from "lucide-react";

import { supabase } from "../lib/supabaseClient";
import { type DBRobot, type DBNode, type DBEdge } from "../types/database";
import { useFleetSocket, type ConnectionStatus } from "../hooks/useFleetSocket";
import { useThemeStore } from "../store/themeStore";
import WaypointNode from "./nodes/WaypointNode";
import { cancelAllDispatches, setFleetPaused } from "../utils/fleetGateway";


// ============================================
// TYPE DEFINITIONS
// ============================================

/** Merged robot data combining DB metadata and live MQTT status */
interface FleetRobot {
  id: number;
  name: string;
  status: "idle" | "busy" | "offline" | "error";
  battery: number;
  x: number;
  y: number;
  currentTask: string;
  isActive: boolean;
  activePath?: string[]; // Readable sequence of node aliases (e.g. ["W1", "W2", "S3"])
}

/** Props for the custom WaypointNode */
interface WaypointNodeData {
  type: string;
  level?: number;
  alias?: string;
}

/** Props for the custom RobotNode */
interface RobotNodeData {
  label: string;
  status: FleetRobot["status"];
  battery: number;
}

// ============================================
// CONSTANTS
// ============================================

/** Map scale factor (meters to pixels) */
const MAP_SCALE = 100;

/** Path polling interval in milliseconds */
const PATH_POLL_INTERVAL_MS = 1000;



// ============================================
// MEMOIZED SUB-COMPONENTS
// ============================================

/** Status colors for robot markers */
const ROBOT_STATUS_COLORS: Record<FleetRobot["status"], string> = {
  idle: "bg-green-500 border-green-300",
  busy: "bg-blue-500 border-blue-300",
  offline: "bg-gray-400 border-gray-300",
  error: "bg-red-500 border-red-300",
} as const;

/** Per-vehicle accent colors for HUD and path edges */
const VEHICLE_COLORS = ["#22c55e", "#3b82f6", "#f59e0b", "#a855f7", "#ef4444"];

/**
 * Robot Node - Animated robot markers with pulsing ring on BUSY status.
 */
const RobotNode = memo<NodeProps<RobotNodeData>>(({ data }) => {
  const { label, status, battery } = data;
  const color = ROBOT_STATUS_COLORS[status] || ROBOT_STATUS_COLORS.offline;
  const isBusy = status === "busy";

  return (
    <div className="relative flex flex-col items-center justify-center pointer-events-none select-none">
      {/* Pulsing ring - only when BUSY */}
      {isBusy && (
        <>
          <div className="absolute w-14 h-14 rounded-full bg-blue-400/30 animate-ping" style={{ animationDuration: "1.2s" }} />
          <div className="absolute w-12 h-12 rounded-full bg-blue-400/20 animate-ping" style={{ animationDuration: "1.6s", animationDelay: "0.3s" }} />
        </>
      )}

      {/* Robot Label */}
      <div className="absolute -top-9 bg-gray-900/95 text-white text-[10px] font-bold px-2.5 py-1 rounded-lg shadow-lg backdrop-blur-sm whitespace-nowrap z-50 border border-white/10">
        {label}
      </div>

      {/* Robot Body */}
      <div
        className={`relative w-11 h-11 ${color} rounded-xl shadow-2xl flex items-center justify-center border-2 z-10`}
        style={{ transition: "background-color 0.3s" }}
      >
        <Truck size={22} className="text-white drop-shadow-sm" />
        {/* Status dot */}
        <div className={`absolute -top-1.5 -right-1.5 w-3 h-3 rounded-full border-2 border-white shadow ${isBusy ? "bg-yellow-400 animate-pulse" : status === "idle" ? "bg-green-300" : "bg-gray-300"}`} />
      </div>

      {/* Battery bar */}
      <div className="absolute -bottom-7 flex flex-col items-center gap-0.5">
        <div className="w-10 h-1.5 bg-gray-700 rounded-full overflow-hidden">
          <div
            className={`h-full rounded-full transition-all duration-500 ${battery > 50 ? "bg-green-400" : battery > 20 ? "bg-yellow-400" : "bg-red-400"}`}
            style={{ width: `${battery}%` }}
          />
        </div>
        <span className="text-[8px] text-gray-300 font-mono">{battery}%</span>
      </div>

      <Handle type="source" position={Position.Bottom} id="mobile-source" style={{ opacity: 0, top: "50%", left: "50%" }} />
      <Handle type="target" position={Position.Top} id="mobile-target" style={{ opacity: 0, top: "50%", left: "50%" }} />
    </div>
  );
});
RobotNode.displayName = "RobotNode";

/**
 * AutoFitView - null-rendering child of ReactFlow that calls fitView when simulation starts.
 * Must live inside <ReactFlow> to use useReactFlow().
 */
const AutoFitView = memo(({ trigger }: { trigger: boolean }) => {
  const { fitView } = useReactFlow();
  const prev = useRef(false);
  useEffect(() => {
    if (trigger && !prev.current) {
      setTimeout(() => fitView({ padding: 0.15, duration: 800 }), 200);
    }
    prev.current = trigger;
  }, [trigger, fitView]);
  return null;
});
AutoFitView.displayName = "AutoFitView";


/**
 * Connection Status Badge - Shows MQTT connection state.
 */
const ConnectionStatusBadge = memo<{
  status: ConnectionStatus;
  reconnectAttempts: number;
  onReconnect: () => void;
}>(({ status, reconnectAttempts, onReconnect }) => {
  const statusConfig = {
    connected: {
      icon: Wifi,
      color: "text-green-500",
      bg: "bg-green-50",
      text: "CONNECTED",
    },
    connecting: {
      icon: RefreshCw,
      color: "text-amber-500",
      bg: "bg-amber-50",
      text: "CONNECTING...",
    },
    reconnecting: {
      icon: RefreshCw,
      color: "text-amber-500",
      bg: "bg-amber-50",
      text: `RECONNECTING (${reconnectAttempts})`,
    },
    disconnected: {
      icon: WifiOff,
      color: "text-red-500",
      bg: "bg-red-50",
      text: "DISCONNECTED",
    },
  };

  const config = statusConfig[status];
  const Icon = config.icon;
  const isAnimated = status === "connecting" || status === "reconnecting";

  return (
    <div
      className={`flex items-center gap-2 px-3 py-1.5 rounded-full ${config.bg} border border-gray-200 dark:border-white/10`}
    >
      <Icon
        size={14}
        className={`${config.color} ${isAnimated ? "animate-spin" : ""}`}
      />
      <span className={`text-xs font-semibold ${config.color}`}>
        {config.text}
      </span>
      {status === "disconnected" && (
        <button
          onClick={onReconnect}
          className="ml-1 text-[10px] bg-slate-200 hover:bg-slate-300 px-2 py-0.5 rounded transition-colors"
        >
          Retry
        </button>
      )}
    </div>
  );
});
ConnectionStatusBadge.displayName = "ConnectionStatusBadge";

/**
 * Robot Table Row - Individual robot data.
 */
const RobotTableRow = memo<{
  robot: FleetRobot;
  onCommand: (robotId: number, command: string, robotName: string) => void;
}>(({ robot, onCommand }) => {
  const handlePause = useCallback(
    () => onCommand(robot.id, "PAUSE", robot.name),
    [robot.id, robot.name, onCommand],
  );
  const handleResume = useCallback(
    () => onCommand(robot.id, "RESUME", robot.name),
    [robot.id, robot.name, onCommand],
  );
  const handleEstop = useCallback(
    () => onCommand(robot.id, "ESTOP", robot.name),
    [robot.id, robot.name, onCommand],
  );

  return (
    <tr className="border-b border-slate-50 last:border-0 hover:bg-gray-100 dark:bg-white/5/50 transition-colors">
      {/* Robot Name & ID */}
      <td className="px-4 py-3">
        <div className="flex items-center gap-2">
          <div className={`p-1.5 rounded-lg ${robot.status === 'idle' ? 'bg-green-100 text-green-600' :
            robot.status === 'busy' ? 'bg-blue-100 text-blue-600' :
              'bg-gray-50 dark:bg-[#09090b] text-gray-900 dark:text-white transition-colors text-gray-500 dark:text-gray-400'
            }`}>
            <Truck size={16} />
          </div>
          <div>
            <div className="font-bold text-xs text-gray-900 dark:text-white">{robot.name}</div>
            <div className="text-[10px] text-gray-500 dark:text-gray-400 font-mono">ID: {robot.id}</div>
          </div>
        </div>
      </td>

      {/* Status Badge */}
      <td className="px-4 py-3">
        <span
          className={`px-2 py-1 rounded text-[10px] font-bold uppercase ${robot.status === "idle"
            ? "bg-green-100 text-green-600"
            : robot.status === "busy"
              ? "bg-blue-100 text-blue-600"
              : "bg-red-100 text-red-600"
            }`}
        >
          {robot.status}
        </span>
      </td>

      {/* Battery */}
      <td className="px-4 py-3">
        <div className={`flex items-center gap-1.5 text-xs font-mono ${robot.battery > 20 ? 'text-slate-600' : 'text-red-500 font-bold'
          }`}>
          <Battery size={14} className={robot.battery > 20 ? 'text-green-500' : 'text-red-500'} />
          {robot.battery}%
        </div>
      </td>

      {/* Current Task & Path */}
      <td className="px-4 py-3 w-1/3">
        <div className="flex flex-col gap-1">
          <div className="flex items-center gap-1.5 text-[10px] font-bold text-gray-500 dark:text-gray-400 uppercase">
            <Activity size={10} /> {robot.currentTask}
          </div>

          {/* Active Path Sequence */}
          {robot.activePath && robot.activePath.length > 0 ? (
            <div className="flex items-center gap-1 text-[10px] text-slate-600 font-mono bg-white border border-gray-200 dark:border-white/10 rounded px-2 py-1 shadow-sm overflow-x-auto max-w-[240px] whitespace-nowrap">
              <MapIcon size={10} className="text-blue-400 shrink-0" />
              {robot.activePath.map((node, i) => (
                <React.Fragment key={i}>
                  <span className={i === 0 ? "font-bold text-blue-600" : ""}>{node}</span>
                  {i < robot.activePath!.length - 1 && (
                    <ChevronsRight size={10} className="text-slate-300 shrink-0" />
                  )}
                </React.Fragment>
              ))}
            </div>
          ) : (
            <span className="text-[10px] text-slate-300 italic">No active path</span>
          )}
        </div>
      </td>

      {/* Actions */}
      <td className="px-4 py-3 text-right">
        <div className="flex items-center justify-end gap-2">
          <button
            onClick={handlePause}
            className="p-1.5 text-amber-600 bg-amber-50 hover:bg-amber-100 border border-amber-200 rounded transition-colors"
            title="Pause Robot"
          >
            <PauseCircle size={16} />
          </button>
          <button
            onClick={handleResume}
            className="p-1.5 text-blue-600 bg-blue-50 hover:bg-blue-100 border border-blue-200 rounded transition-colors"
            title="Resume Robot"
          >
            <PlayCircle size={16} />
          </button>
          <div className="w-px h-4 bg-slate-200 mx-1" />
          <button
            onClick={handleEstop}
            className="p-1.5 text-red-600 bg-red-50 hover:bg-red-100 border border-red-200 rounded transition-colors"
            title="EMERGENCY STOP"
          >
            <AlertOctagon size={16} />
          </button>
        </div>
      </td>
    </tr>
  );
});
RobotTableRow.displayName = "RobotTableRow";


// ============================================
// MAIN COMPONENT
// ============================================

interface FleetControllerProps {
  graphId: number;
  simulationRoutes?: number[][] | null;
}

const FleetController: React.FC<FleetControllerProps> = ({ graphId, simulationRoutes }) => {
  const { theme } = useThemeStore();

  // --- NODE TYPES (memoized outside render loop) ---
  const nodeTypes = useMemo(
    () => ({
      waypointNode: WaypointNode,
      robotNode: RobotNode,
    }),
    [],
  );

  const defaultEdgeOptions = useMemo(() => ({ type: "straight" }), []);

  // --- STATE ---
  const [dbRobots, setDbRobots] = useState<DBRobot[]>([]);
  const [cellMap, setCellMap] = useState<Map<number, number>>(new Map());
  const [nodeAliasMap, setNodeAliasMap] = useState<Map<number, string>>(new Map());
  const [nodesLoaded, setNodesLoaded] = useState(false);

  // Track active paths per robot (robotId -> list of node aliases)
  const [robotPathDetails, setRobotPathDetails] = useState<Map<number, string[]>>(new Map());

  // React Flow state
  const [nodes, setNodes, onNodesChange] = useNodesState([]);
  const [edges, setEdges, onEdgesChange] = useEdgesState([]);

  // MQTT Hook (production-grade)
  const {
    connectionStatus,
    robotStates,
    logs,
    reconnectAttempts,
    publishCommand,
    forceReconnect,
    addLog,
  } = useFleetSocket();

  // --- REFS (to avoid stale closures) ---
  const nodePositionsRef = useRef<Map<string, { x: number; y: number }>>(new Map());
  const nodeAliasMapRef = useRef<Map<number, string>>(new Map());

  // Update nodePositionsRef whenever nodes change
  useEffect(() => {
    const newPositions = new Map<string, { x: number; y: number }>();
    nodes.forEach(n => {
      // Skip the background image node
      if (n.id === 'map-bg') return;
      newPositions.set(n.id, { x: n.position.x, y: n.position.y });
    });
    nodePositionsRef.current = newPositions;
  }, [nodes]);

  // Sync nodeAliasMap into a ref so simulation interval has a fresh reference
  useEffect(() => {
    nodeAliasMapRef.current = nodeAliasMap;
  }, [nodeAliasMap]);

  // --- LOAD STATIC DATA (Graph + Robots + Cells) ---
  useEffect(() => {
    if (!graphId) return;

    const loadStaticData = async () => {
      try {
        // Load Graph
        const { data: graphData } = await supabase
          .from("wh_graphs")
          .select("*")
          .eq("id", graphId)
          .single();

        if (!graphData) {
          console.warn("[FleetController] No graph found for id:", graphId);
          return;
        }

        // Load Nodes
        const { data: nodeData } = await supabase
          .from("wh_nodes_view")
          .select("*")
          .eq("graph_id", graphId);

        if (nodeData) {
          const aliasMap = new Map<number, string>();

          const flowNodes: Node[] = nodeData.map((n: DBNode) => {
            aliasMap.set(n.id, n.alias || `Node ${n.id}`);
            return {
              id: n.id.toString(),
              type: "waypointNode",
              position: { x: n.x * MAP_SCALE, y: n.y * MAP_SCALE },
              data: { type: n.type, level: n.level, alias: n.alias } as WaypointNodeData,
              draggable: false,
              selectable: false,
            };
          });

          setNodeAliasMap(aliasMap);
          setNodesLoaded(true);

          // Add Map Background
          if (graphData.map_url) {
            let mapX = 0, mapY = 0, mapW = 1200, mapH = 800;
            let cleanUrl = graphData.map_url;

            if (graphData.map_url.includes('#')) {
              const [base, hash] = graphData.map_url.split('#');
              cleanUrl = base;
              const params = new URLSearchParams(hash);
              if (params.has('x')) mapX = parseFloat(params.get('x') || '0');
              if (params.has('y')) mapY = parseFloat(params.get('y') || '0');
              if (params.has('w')) mapW = parseFloat(params.get('w') || '1200');
              if (params.has('h')) mapH = parseFloat(params.get('h') || '800');
            }

            flowNodes.unshift({
              id: "map-bg",
              type: "default",
              position: { x: mapX, y: mapY },
              data: { label: null },
              style: {
                width: mapW,
                height: mapH,
                backgroundImage: `url('${cleanUrl}')`,
                backgroundSize: "contain",
                zIndex: -11,
                pointerEvents: 'none',
                backgroundColor: 'transparent',
                border: 'none',
              },
              draggable: false,
              selectable: false,
            });
          }
          setNodes(flowNodes);
        }

        // Load Edges
        const { data: edgeData } = await supabase
          .from("wh_edges")
          .select("*")
          .eq("graph_id", graphId);

        if (edgeData) {
          setEdges(
            edgeData.map((e: DBEdge) => ({
              id: `e${e.node_a_id}-${e.node_b_id}`,
              source: e.node_a_id.toString(),
              target: e.node_b_id.toString(),
              animated: true,
              style: { stroke: '#3b82f6', strokeWidth: 2, strokeDasharray: '5,5' },
              markerEnd: { type: MarkerType.ArrowClosed, color: '#3b82f6' },
              type: 'straight'
            })),
          );
        }

        // Load Cells (for path visualization)
        const { data: cellData } = await supabase
          .from("wh_cells")
          .select("id, node_id");
        if (cellData) {
          const map = new Map<number, number>();
          cellData.forEach((c) => map.set(c.id, c.node_id));
          setCellMap(map);
        }

        // Load Robots
        try {
          const { data: robotData, error } = await supabase
            .from("wh_robots")
            .select("*");
          if (error) throw error;
          if (robotData) {
            setDbRobots(robotData as DBRobot[]);
          }
        } catch (e) {
          console.warn("[FleetController] wh_robots error, using mock.", e);
        }
      } catch (err) {
        console.error("[FleetController] Error loading static data:", err);
      }
    };

    loadStaticData();
  }, [graphId, setNodes, setEdges]);

  // --- MERGE DB ROBOTS + MQTT STATUS (derived state) ---
  const robots = useMemo<FleetRobot[]>(() => {
    if (dbRobots.length === 0) return [];

    return dbRobots.map((dbBot) => {
      const liveData = robotStates[dbBot.id] || robotStates[dbBot.name];
      const activePath = robotPathDetails.get(dbBot.id);

      return {
        id: dbBot.id,
        name: dbBot.name,
        status: (liveData?.status || "offline") as FleetRobot["status"],
        battery: liveData?.battery || 0,
        x: liveData ? liveData.x * MAP_SCALE : 50,
        y: liveData ? liveData.y * MAP_SCALE : 50 + dbBot.id * 50,
        currentTask: liveData?.current_task_id
          ? `Task #${liveData.current_task_id}`
          : "Idle",
        isActive: !!liveData,
        activePath // Attach the path alias sequence
      };
    });
  }, [dbRobots, robotStates, robotPathDetails]);

  // --- UPDATE ROBOT NODES IN REACTFLOW ---
  useEffect(() => {
    if (robots.length === 0) return;

    setNodes((prevNodes) => {
      const staticNodes = prevNodes.filter((n) => n.type !== "robotNode");
      const robotNodes: Node[] = robots.map((r) => ({
        id: `robot-${r.id}`,
        type: "robotNode",
        position: { x: r.x, y: r.y },
        data: {
          label: r.name,
          status: r.status,
          battery: r.battery,
        } as RobotNodeData,
        draggable: false,
        zIndex: 100,
      }));
      return [...staticNodes, ...robotNodes];
    });
  }, [robots, setNodes]);

  // --- SIMULATION ENGINE: Animate dummy robots along VRP routes ---
  const simIntervalRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const simStepRef = useRef<number[]>([]); // current step index per vehicle
  const currentSimRoutesRef = useRef<string>(""); // Track currently running simulation to prevent double-starts
  const simPausedRef = useRef(false); // Read inside interval callback without stale-closure issues

  useEffect(() => {
    // Cleanup any existing simulation
    if (simIntervalRef.current) {
      clearInterval(simIntervalRef.current);
      simIntervalRef.current = null;
    }

    if (!simulationRoutes || simulationRoutes.length === 0) {
      // Clear simulation path edges
      setEdges((prev) => prev.filter((e) => !e.id.startsWith("sim-path-")));
      setRobotPathDetails(new Map());
      currentSimRoutesRef.current = "";
      return;
    }

    // Wait for nodes to be loaded from the database before spawning robots
    if (!nodesLoaded) return;

    const newSimHash = JSON.stringify(simulationRoutes);
    if (newSimHash === currentSimRoutesRef.current) {
      return; // Already running this simulation
    }
    currentSimRoutesRef.current = newSimHash;

    // Initialize step counters and reset pause state
    simStepRef.current = simulationRoutes.map(() => 0);
    simPausedRef.current = false;
    addLog("[Simulation] Route dispatched - highlighting paths");

    // Build node position map from current static nodes
    const getNodePos = (nodeId: number): { x: number; y: number } | null => {
      return nodePositionsRef.current.get(String(nodeId)) || null;
    };

    // Set initial path details for table
    const initialPathDetails = new Map<number, string[]>();
    simulationRoutes.forEach((route, vi) => {
      const aliases = route.map((nid) => nodeAliasMap.get(nid) || `Node ${nid}`);
      initialPathDetails.set(vi, aliases);
    });
    setRobotPathDetails(initialPathDetails);

    // Highlight all path edges
    const simEdges: Edge[] = [];
    simulationRoutes.forEach((route, vi) => {
      for (let i = 0; i < route.length - 1; i++) {
        simEdges.push({
          id: `sim-path-${vi}-${i}`,
          source: String(route[i]),
          target: String(route[i + 1]),
          animated: true,
          style: { stroke: VEHICLE_COLORS[vi % VEHICLE_COLORS.length], strokeWidth: 3 },
          zIndex: 5,
          type: "straight",
        });
      }
    });

    setEdges((prev) => {
      const withoutSimEdges = prev.filter((e) => !e.id.startsWith("sim-path-"));
      return [...withoutSimEdges, ...simEdges];
    });

    // Defer interval start by one tick so nodePositionsRef is populated
    const startSimulation = () => {
      simIntervalRef.current = setInterval(() => {
        // Pause: skip tick but keep interval alive so resume restarts from same position
        if (simPausedRef.current) return;

        let allDone = true;

        const edgesToDim: string[] = [];
        const logMessages: string[] = [];

        simulationRoutes.forEach((route, vi) => {
          const currentStep = simStepRef.current[vi];
          if (currentStep >= route.length - 1) return; // Vehicle finished

          allDone = false;
          const nextStep = currentStep + 1;
          simStepRef.current[vi] = nextStep;

          const nextNodeId = route[nextStep];
          if (nextNodeId !== undefined) {
            const nodeAlias = nodeAliasMapRef.current.get(nextNodeId) || `Node ${nextNodeId}`;
            if (nextStep % 3 === 0) {
              logMessages.push(`[Route] V${vi + 1} → ${nodeAlias}`);
            }
          }

          // Dim traversed edges
          if (nextStep > 0) {
            edgesToDim.push(`sim-path-${vi}-${currentStep - 1}`);
          }
        });

        if (edgesToDim.length > 0) {
          const dimSet = new Set(edgesToDim);
          setEdges((prev) =>
            prev.map((e) =>
              dimSet.has(e.id) ? { ...e, animated: false, style: { ...e.style, opacity: 0.3 } } : e
            )
          );
        }
        logMessages.forEach((msg) => addLog(msg));

        if (allDone) {
          addLog("[Simulation] All vehicles have reached their destinations");
          if (simIntervalRef.current) {
            clearInterval(simIntervalRef.current);
            simIntervalRef.current = null;
          }
        }
      }, 1200); // Move every 1.2 seconds
    };

    // Defer by one tick so nodePositionsRef has synced after setNodes calls above
    const startTimeout = setTimeout(startSimulation, 50);

    return () => {
      clearTimeout(startTimeout);
      if (simIntervalRef.current) {
        clearInterval(simIntervalRef.current);
        simIntervalRef.current = null;
      }
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [simulationRoutes, nodesLoaded]);

  // --- PATH VISUALIZATION & SEQUENCE EXTRACTION ---
  useEffect(() => {
    if (robots.length === 0 || cellMap.size === 0 || nodeAliasMap.size === 0) return;

    const fetchPaths = async () => {
      try {
        const { data: assignments } = await supabase
          .from("wh_assignments")
          .select("id, robot_id")
          .eq("status", "in_progress");

        if (!assignments || assignments.length === 0) {
          setEdges((prev) => prev.filter((e) => !e.id.startsWith("path-")));
          setRobotPathDetails(new Map()); // Clear paths
          return;
        }

        const assignmentIds = assignments.map((a) => a.id);
        const { data: tasks } = await supabase
          .from("wh_tasks")
          .select("*")
          .in("assignment_id", assignmentIds)
          .neq("status", "delivered")
          .order("seq_order");

        if (!tasks) return;

        const pathEdges: Edge[] = [];
        const newPathDetails = new Map<number, string[]>();

        assignments.forEach((asn) => {
          const asnTasks = tasks.filter((t) => t.assignment_id === asn.id);
          if (asnTasks.length === 0) return;

          const bot = robots.find((r) => r.id === asn.robot_id) || robots[0];
          let prevSource = bot ? `robot-${bot.id}` : null;
          let prevSourceHandle = "mobile-source";

          // Extract path aliases for the table
          const aliasSequence: string[] = [];

          asnTasks.forEach((task, i) => {
            const targetNodeId = cellMap.get(task.cell_id);
            if (!targetNodeId) return;

            // Get Alias
            const alias = nodeAliasMap.get(targetNodeId);
            if (alias) aliasSequence.push(alias);

            const targetHandle = targetNodeId.toString();

            if (prevSource) {
              pathEdges.push({
                id: `path-${asn.id}-${i}`,
                source: prevSource,
                sourceHandle: prevSourceHandle,
                target: targetHandle,
                targetHandle: "top-target",
                animated: true,
                style: {
                  stroke: "#22c55e",
                  strokeWidth: 2,
                  strokeDasharray: "5,5",
                },
                type: 'straight'
              });
            }
            prevSource = targetHandle;
            prevSourceHandle = "bottom-source";
          });

          // Store for table display
          if (asn.robot_id) {
            newPathDetails.set(asn.robot_id, aliasSequence);
          }
        });

        setRobotPathDetails(newPathDetails);

        setEdges((prev) => {
          const mapEdges = prev.filter((e) => !e.id.startsWith("path-"));
          return [...mapEdges, ...pathEdges];
        });
      } catch (err) {
        console.error("[FleetController] Error fetching paths:", err);
      }
    };

    fetchPaths();
    const interval = setInterval(fetchPaths, PATH_POLL_INTERVAL_MS);
    return () => clearInterval(interval);
  }, [robots, cellMap, nodeAliasMap, setEdges]);

  // --- COMMAND HANDLER (stable callback) ---
  const handleCommand = useCallback(
    (robotId: number, command: string, robotName: string) => {
      console.log(`[FleetController] Sending ${command} to Robot ${robotId}`);
      if (command === "PAUSE") {
        setFleetPaused(true);
        simPausedRef.current = true;
      } else if (command === "RESUME") {
        setFleetPaused(false);
        simPausedRef.current = false;
      } else if (command === "ESTOP" || command === "CANCEL") {
        setFleetPaused(true);
        simPausedRef.current = true;
        cancelAllDispatches();
      }
      publishCommand(robotId, command as "PAUSE" | "RESUME" | "ESTOP" | "CANCEL", { robotName });
    },
    [publishCommand],
  );

  // --- RENDER ---
  return (
    <div className="w-full h-full bg-gray-50 dark:bg-[#09090b] text-gray-900 dark:text-white transition-colors relative font-sans">
      <ReactFlow
        nodes={nodes}
        edges={edges}
        nodeTypes={nodeTypes}
        onNodesChange={onNodesChange}
        onEdgesChange={onEdgesChange}
        fitView
        minZoom={0.05}
        maxZoom={4}
        panOnScroll
        selectionOnDrag={false}
        panOnDrag
        defaultEdgeOptions={defaultEdgeOptions}
      >
        <Background
          color={theme === "dark" ? "#1e293b" : "#cbd5e1"}
          gap={20}
          size={1}
          variant={BackgroundVariant.Dots}
        />

        {/* Header Panel */}
        <Panel position="top-left" className="m-6">
          <div className="bg-white/90 dark:bg-[#121214]/90 backdrop-blur-md border border-gray-200 dark:border-white/10 shadow-xl px-5 py-4 rounded-2xl flex items-center gap-4 text-gray-900 dark:text-white transition-colors">
            <div className="p-2.5 bg-gradient-to-br from-blue-50 to-indigo-50 dark:from-blue-500/20 dark:to-indigo-500/10 border border-blue-100 dark:border-white/5 text-blue-600 dark:text-blue-400 rounded-xl shadow-inner">
              <Truck size={22} className="drop-shadow-sm" />
            </div>
            <div>
              <h2 className="text-lg font-black tracking-tight leading-none bg-clip-text text-transparent bg-gradient-to-r from-gray-800 to-gray-500 dark:from-white dark:to-gray-400">
                Fleet Controller
              </h2>
              <div className="text-[11px] font-bold text-gray-500 dark:text-gray-400 mt-1.5 flex items-center gap-3">
                <ConnectionStatusBadge
                  status={simulationRoutes && simulationRoutes.length > 0 && connectionStatus === 'disconnected' ? 'connected' : connectionStatus}
                  reconnectAttempts={reconnectAttempts}
                  onReconnect={forceReconnect}
                />
                <span className="text-gray-300 dark:text-gray-700">|</span>
                <span className="flex items-center gap-1.5">
                  <span className="uppercase tracking-wider">Active:</span>
                  <span className="text-gray-900 dark:text-white bg-gray-100 dark:bg-white/10 px-2 py-0.5 rounded-full shadow-sm">
                    {robots.filter((r) => r.isActive).length}
                  </span>
                </span>
              </div>
            </div>
          </div>
        </Panel>

        {/* Auto-fit view when simulation starts */}
        <AutoFitView trigger={!!(simulationRoutes && simulationRoutes.length > 0)} />

        {/* BOTTOM PANEL - ROBOT TABLE & LOGS */}
        <Panel position="bottom-center" className="m-4 w-[95%] max-w-5xl flex gap-4" style={{ pointerEvents: 'none' }}>

          {/* Main Table */}
          <div className="flex-1 bg-white/95 dark:bg-[#121214]/90 backdrop-blur-md border border-gray-200 dark:border-white/10 rounded-2xl shadow-xl overflow-hidden flex flex-col max-h-64 pointer-events-auto">
            <div className="bg-gradient-to-r from-gray-50 to-white dark:from-white/5 dark:to-transparent px-5 py-3 border-b border-gray-100 dark:border-white/5 flex justify-between items-center">
              <h3 className="text-xs font-bold text-gray-700 dark:text-gray-300 uppercase flex items-center gap-2">
                <Activity size={16} className="text-blue-500" /> Active Fleet Status
              </h3>
            </div>

            <div className="overflow-y-auto flex-1 custom-scrollbar">
              <table className="w-full text-left border-collapse">
                <thead className="bg-gray-50/80 dark:bg-white/5 sticky top-0 z-10 text-[10px] font-bold text-gray-500 dark:text-gray-400 uppercase tracking-wider backdrop-blur-sm">
                  <tr>
                    <th className="px-5 py-3 border-b border-gray-100 dark:border-white/5">Identity</th>
                    <th className="px-5 py-3 border-b border-gray-100 dark:border-white/5">Status</th>
                    <th className="px-5 py-3 border-b border-gray-100 dark:border-white/5">Battery</th>
                    <th className="px-5 py-3 border-b border-gray-100 dark:border-white/5">Current Activity & Path</th>
                    <th className="px-5 py-3 border-b border-gray-100 dark:border-white/5 text-right">Controls</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-gray-50 dark:divide-white/5">
                  {/* Render Live Robots from DB */}
                  {robots.map((r) => (
                    <RobotTableRow
                      key={`live-${r.id}`}
                      robot={r}
                      onCommand={handleCommand}
                    />
                  ))}

                  {robots.length === 0 && (
                    <tr>
                      <td colSpan={5} className="px-5 py-10 text-center text-gray-500 dark:text-gray-400 text-xs italic opacity-70">
                        No robots detected in fleet.
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>
          </div>

          {/* Logs Side Panel */}
          <div className="w-72 hidden md:block pointer-events-auto">
            <div className="bg-white/95 dark:bg-[#121214]/90 backdrop-blur-md border border-gray-200 dark:border-white/10 rounded-2xl shadow-xl flex flex-col overflow-hidden h-full max-h-64">
              <div className="bg-gradient-to-r from-gray-50 to-white dark:from-white/5 dark:to-transparent px-4 py-3 border-b border-gray-100 dark:border-white/5 flex justify-between items-center">
                <span className="text-[10px] font-bold text-gray-700 dark:text-gray-300 uppercase flex items-center gap-1.5">
                  <Terminal size={14} className="text-gray-400" /> System Logs
                </span>
                <span className="w-2 h-2 rounded-full bg-green-500 shadow-[0_0_8px_rgba(34,197,94,0.6)] animate-pulse" />
              </div>
              <div className="flex-1 overflow-y-auto p-3 space-y-1.5 custom-scrollbar">
                {logs.length === 0 && (
                  <div className="text-[10px] text-gray-500 dark:text-gray-500/70 italic text-center py-4">
                    Waiting for events...
                  </div>
                )}
                {logs.map((log, i) => (
                  <div
                    key={i}
                    className="text-[10px] font-mono text-gray-600 dark:text-gray-400 border-b border-gray-50 dark:border-white/5 last:border-0 pb-1.5 break-words"
                  >
                    {log}
                  </div>
                ))}
              </div>
            </div>
          </div>

        </Panel>

        <Controls className="!bg-white !border-gray-200 dark:border-white/10 !text-slate-600 !fill-slate-600 shadow-lg" />
        <MiniMap
          className="!bg-gray-100 dark:bg-white/5 border border-gray-200 dark:border-white/10 rounded-lg shadow-lg"
          nodeColor={(n) => (n.type === "robotNode" ? "#ef4444" : "#94a3b8")}
        />

      </ReactFlow>
    </div>
  );
};

export default FleetController;
