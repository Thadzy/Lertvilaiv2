import React, { useCallback, useMemo, useEffect, useState } from 'react';
import ReactFlow, {
  Background,
  Controls,
  MiniMap,
  useNodesState,
  useEdgesState,
  addEdge,
  type Connection,
  type Node,
  Panel,
  MarkerType,
  BackgroundVariant,
  type NodeProps,
  ConnectionLineType,
  applyNodeChanges,
  type NodeChange,
} from 'reactflow';

import 'reactflow/dist/style.css';
import { NodeResizer } from '@reactflow/node-resizer';
import '@reactflow/node-resizer/dist/style.css';
import {
  Save,
  PlusCircle,
  LayoutGrid,
  MousePointer2,
  Trash2,
  Upload,
  RefreshCw,
  XCircle,
  Link as LinkIcon,
  Box, 
  ArrowUpFromLine, 
  CircleDot, 
  Layers, 
  Home, 
  Edit3,
  Plus,
  ChevronDown,
  Lock,
  Unlock,
} from 'lucide-react';


import { useGraphData, type Level } from '../hooks/useGraphData';
import { supabase } from '../lib/supabaseClient';
import { useThemeStore } from '../store/themeStore';
import WaypointNode from './nodes/WaypointNode';


// --- CENTRALIZED NODE COMPONENTS ---

const MapNode = ({ data, selected }: NodeProps) => {
  return (
    <>
      <NodeResizer color="#3b82f6" isVisible={selected} minWidth={100} minHeight={100} />
      <img
        src={data.url}
        alt="Map Background"
        style={{ width: '100%', height: '100%', objectFit: 'contain', pointerEvents: 'none' }}
        draggable={false}
      />
    </>
  );
};

const nodeTypes = { waypointNode: WaypointNode, mapNode: MapNode };

// --- MAIN COMPONENT PROPS ---
interface GraphEditorProps {
  graphId: number;
  visualizedPath?: string[];
}

// --- MAIN COMPONENT ---
const GraphEditor: React.FC<GraphEditorProps> = ({ graphId, visualizedPath = [] }) => {
  const { theme } = useThemeStore();
  const [nodes, setNodes] = useNodesState([]);

  const [edges, setEdges, onEdgesChange] = useEdgesState([]);

  // Editor State
  const [bgUrl, setBgUrl] = useState<string | null>(null);
  const [mapLocked, setMapLocked] = useState(true);
  const [uploading, setUploading] = useState(false);
  const [toolMode, setToolMode] = useState<'move' | 'connect'>('move');



  // Level State
  const [levels, setLevels] = useState<Level[]>([]);
  const [selectedLevel, setSelectedLevel] = useState<number | null>(null); // null = ALL
  const [showLevelManager, setShowLevelManager] = useState(false);
  const [newLevelAlias, setNewLevelAlias] = useState('');
  const [newLevelHeight, setNewLevelHeight] = useState('0');

  // Shelf Detail State
  const [showShelfPanel, setShowShelfPanel] = useState(false);
  const [shelfCells, setShelfCells] = useState<{ id: number; alias: string; levelAlias: string | null; level_id: number | null }[]>([]);
  const [newCellAlias, setNewCellAlias] = useState('');
  const [newCellLevel, setNewCellLevel] = useState('');

  // All nodes (before level filter)
  const [allNodes, setAllNodes] = useState<Node[]>([]);

  // Custom Hook for Supabase Data
  const { loadGraph, saveGraph, loading, createLevel, deleteLevel, createCell, deleteCell } = useGraphData(graphId);

  // Helper: Get currently selected node
  const selectedNode = useMemo(() => nodes.find((n) => n.selected), [nodes]);

  // Helper: Update a specific property of the selected node
  const updateSelectedNode = (key: string, value: any) => {
    setNodes((nds) =>
      nds.map((node) => {
        if (node.selected) {
          return { ...node, data: { ...node.data, [key]: value } };
        }
        return node;
      })
    );
    // Also update allNodes
    setAllNodes((nds) =>
      nds.map((node) => {
        if (node.id === selectedNode?.id) {
          return { ...node, data: { ...node.data, [key]: value } };
        }
        return node;
      })
    );
  };

  // --- 1. LOAD DATA ---
  useEffect(() => {
    const fetchData = async () => {
      const { nodes: dbNodes, edges: dbEdges, mapUrl, levels: dbLevels } = await loadGraph();

      // Apply current lock state to the incoming map background node
      const preparedNodes = dbNodes.map(n => n.id === 'map-background' ? { ...n, draggable: !mapLocked, selectable: !mapLocked } : n);

      setAllNodes(preparedNodes);
      setNodes(preparedNodes);
      setEdges(dbEdges);
      setBgUrl(mapUrl || null);
      setLevels(dbLevels);
    };

    fetchData();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [graphId]);

  // --- LEVEL FILTER EFFECT ---
  useEffect(() => {
    if (selectedLevel === null) {
      // Show ALL
      setNodes(allNodes.map(n => n.id === 'map-background' ? { ...n, draggable: !mapLocked, selectable: !mapLocked } : n));
    } else {
      // Filter: show non-cell nodes + cells matching selected level
      setNodes(
        allNodes.filter(n => {
          if (n.id === 'map-background') return true;
          if (n.data?.type !== 'cell') return true;
          return n.data?.level_id === selectedLevel;
        }).map(n => n.id === 'map-background' ? { ...n, draggable: !mapLocked, selectable: !mapLocked } : n)
      );
    }
  }, [selectedLevel, allNodes, mapLocked]);

  // --- SHELF DETAIL: populate cells when a shelf is selected ---
  useEffect(() => {
    if (selectedNode && selectedNode.data?.type === 'shelf') {
      const shelfId = Number(selectedNode.id);
      if (!isNaN(shelfId)) {
        const cells = allNodes
          .filter(n => n.data?.type === 'cell' && n.data?.shelf_id === shelfId)
          .map(n => ({
            id: Number(n.id),
            alias: n.data.label || 'unnamed',
            levelAlias: n.data.levelAlias || null,
            level_id: n.data.level_id || null,
          }));
        setShelfCells(cells);
        setShowShelfPanel(true);
      }
    } else {
      setShowShelfPanel(false);
    }
  }, [selectedNode, allNodes]);

  // --- 2. PATH VISUALIZATION EFFECT ---
  useEffect(() => {
    if (!visualizedPath || visualizedPath.length < 2) {
      setEdges((eds) =>
        eds.map((e) => ({
          ...e,
          animated: true,
          style: { stroke: '#3b82f6', strokeWidth: 2, strokeDasharray: '5,5' },
          zIndex: 0
        }))
      );
      return;
    }

    const aliasToIdMap = new Map<string, string>();
    nodes.forEach(node => {
      if (node.data?.label) {
        aliasToIdMap.set(node.data.label, node.id);
      }
    });

    const pathEdgeIds = new Set<string>();

    for (let i = 0; i < visualizedPath.length - 1; i++) {
      const sourceAlias = visualizedPath[i];
      const targetAlias = visualizedPath[i + 1];
      const sourceId = aliasToIdMap.get(sourceAlias);
      const targetId = aliasToIdMap.get(targetAlias);
      if (sourceId && targetId) {
        const edge = edges.find(e =>
          (e.source === sourceId && e.target === targetId) ||
          (e.source === targetId && e.target === sourceId)
        );
        if (edge) pathEdgeIds.add(edge.id);
      }
    }

    setEdges((eds) =>
      eds.map((e) => {
        if (pathEdgeIds.has(e.id)) {
          return { ...e, animated: true, style: { stroke: '#22c55e', strokeWidth: 4 }, zIndex: 10 };
        } else {
          return { ...e, animated: true, style: { stroke: '#94a3b8', strokeWidth: 1, strokeDasharray: '5,5', opacity: 0.5 }, zIndex: 0 };
        }
      })
    );
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [JSON.stringify(visualizedPath), nodes.length]);


  // --- 3. HANDLERS ---
  const handleNodesChange = useCallback((changes: NodeChange[]) => {
    setNodes((nds) => applyNodeChanges(changes, nds));
    setAllNodes((nds) => applyNodeChanges(changes, nds));
  }, [setNodes, setAllNodes]);

  const onConnect = useCallback(
    (params: Connection) => {
      const newEdge = {
        ...params,
        type: 'straight',
        animated: true,
        style: { stroke: '#3b82f6', strokeWidth: 2, strokeDasharray: '5,5' },
        markerEnd: { type: MarkerType.ArrowClosed, color: '#3b82f6' },
      };
      setEdges((eds) => addEdge(newEdge, eds));
    },
    [setEdges]
  );

  const addNode = (type: 'waypoint' | 'conveyor' | 'shelf' = 'waypoint') => {
    const id = `temp_${Date.now()}`;
    const prefixMap = { waypoint: 'W', conveyor: 'C', shelf: 'S' };
    const newNode: Node = {
      id,
      type: 'waypointNode',
      position: {
        x: 100 + Math.random() * 200,
        y: 100 + Math.random() * 200,
      },
      data: {
        label: `${prefixMap[type]}_${nodes.filter(n => n.data?.type === type).length + 1}`,
        type,
        height: type === 'conveyor' ? 1.0 : undefined,
      },
    };
    setNodes((nds) => nds.concat(newNode));
    setAllNodes((nds) => nds.concat(newNode));
    setToolMode('move');
  };

  const handleDelete = useCallback(() => {
    // Prevent deleting depot and cell nodes from canvas
    setNodes((nds) => nds.filter((node) => !node.selected || node.data?.type === 'depot' || node.data?.type === 'cell'));
    setAllNodes((nds) => nds.filter((node) => !node.selected || node.data?.type === 'depot' || node.data?.type === 'cell'));
    setEdges((eds) => eds.filter((edge) => !edge.selected));
  }, [setNodes, setEdges]);

  // Upload Map Image
  const handleFileUpload = async (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    if (!file) return;

    try {
      setUploading(true);
      const fileName = `map_${graphId}_${Date.now()}_${file.name.replace(/\s/g, '')}`;

      const { error: uploadError } = await supabase.storage.from('maps').upload(fileName, file);
      if (uploadError) throw uploadError;

      const { data: { publicUrl } } = supabase.storage.from('maps').getPublicUrl(fileName);

      // Try direct table update (may fail on local schema with SECURITY DEFINER)
      const { error: updateError } = await supabase.from('wh_graphs').update({ map_url: publicUrl }).eq('id', graphId);
      if (updateError) {
        console.warn('[GraphEditor] Could not update map_url directly:', updateError.message);
      }

      setBgUrl(publicUrl);
      alert('Map uploaded successfully!');
    } catch (error: unknown) {
      const msg = error instanceof Error ? error.message : 'Unknown error';
      console.error(error);
      alert(`Upload failed: ${msg}`);
    } finally {
      setUploading(false);
      if (event.target) event.target.value = ''; // Reset input to allow re-uploading the same file
    }
  };

  const handleRemoveBackground = async () => {
    if (!window.confirm("Are you sure you want to remove the background map?")) return;
    try {
      setUploading(true);
      // Try direct table update (may fail on local schema with SECURITY DEFINER)
      const { error } = await supabase.from('wh_graphs').update({ map_url: null }).eq('id', graphId);
      if (error) {
        console.warn('[GraphEditor] Could not remove map_url directly:', error.message);
      }
      setBgUrl(null);
    } catch {
      alert('Failed to remove image');
    } finally {
      setUploading(false);
    }
  };

  // Level Management
  const handleCreateLevel = async () => {
    if (!newLevelAlias.trim()) return;
    const result = await createLevel(newLevelAlias.trim(), parseFloat(newLevelHeight) || 0);
    if (result) {
      setNewLevelAlias('');
      setNewLevelHeight('0');
      // Reload to get updated levels
      const { levels: updatedLevels } = await loadGraph();
      setLevels(updatedLevels);
    }
  };

  const handleDeleteLevel = async (levelId: number) => {
    if (!window.confirm('Delete this level? All cells on this level will also be deleted.')) return;
    const success = await deleteLevel(levelId);
    if (success) {
      const { nodes: dbNodes, edges: dbEdges, levels: updatedLevels } = await loadGraph();
      setAllNodes(dbNodes);
      setNodes(dbNodes);
      setEdges(dbEdges);
      setLevels(updatedLevels);
      if (selectedLevel === levelId) setSelectedLevel(null);
    }
  };

  // Cell Management (via Shelf)
  const handleCreateCell = async () => {
    if (!selectedNode || selectedNode.data?.type !== 'shelf') return;
    if (!newCellAlias.trim() || !newCellLevel) return;

    const shelfAlias = selectedNode.data.label;
    const levelObj = levels.find(l => l.id === parseInt(newCellLevel));
    if (!levelObj) return;

    const result = await createCell(shelfAlias, levelObj.alias, newCellAlias.trim());
    if (result) {
      setNewCellAlias('');
      setNewCellLevel('');
      // Reload graph
      const { nodes: dbNodes, edges: dbEdges, levels: updatedLevels } = await loadGraph();
      setAllNodes(dbNodes);
      setNodes(dbNodes);
      setEdges(dbEdges);
      setLevels(updatedLevels);
    }
  };

  const handleDeleteCell = async (cellId: number) => {
    if (!window.confirm('Delete this cell?')) return;
    const success = await deleteCell(cellId);
    if (success) {
      const { nodes: dbNodes, edges: dbEdges, levels: updatedLevels } = await loadGraph();
      setAllNodes(dbNodes);
      setNodes(dbNodes);
      setEdges(dbEdges);
      setLevels(updatedLevels);
    }
  };

  // Reload helper
  const reloadGraph = async () => {
    const { nodes: dbNodes, edges: dbEdges, mapUrl, levels: dbLevels } = await loadGraph();
    setAllNodes(dbNodes);
    setNodes(dbNodes);
    setEdges(dbEdges);
    setBgUrl(mapUrl || null);
    setLevels(dbLevels);
  };

  // --- Node type label for "add" dropdown ---
  const [showAddMenu, setShowAddMenu] = useState(false);

  return (
    <div className="w-full h-full bg-gray-50 dark:bg-[#09090b] text-gray-900 dark:text-white relative font-sans transition-colors">

      <ReactFlow
        nodes={nodes}
        edges={edges}
        nodeTypes={nodeTypes}
        onNodesChange={handleNodesChange}
        onEdgesChange={onEdgesChange}
        onConnect={onConnect}
        fitView
        minZoom={0.1}
        maxZoom={4}
        defaultEdgeOptions={{ 
          type: 'straight',
          style: { stroke: theme === 'dark' ? '#3b82f6' : '#2563eb', strokeWidth: 3 },
          markerEnd: { type: MarkerType.ArrowClosed, color: theme === 'dark' ? '#3b82f6' : '#2563eb' }
        }}

        connectionLineType={ConnectionLineType.Straight}
        nodesDraggable={toolMode === 'move'}
        nodesConnectable={toolMode === 'connect'}
        onPaneClick={() => setNodes((nds) => nds.map((n) => ({ ...n, selected: false })))}
      >

        <Background color={theme === 'dark' ? '#1e293b' : '#cbd5e1'} gap={20} size={1} variant={BackgroundVariant.Dots} />


        {/* --- HEADER INFO --- */}
        <Panel position="top-left" className="m-4">
          <div className="bg-white/90 dark:bg-[#121214]/90 dark:bg-[#121214]/90 backdrop-blur border border-gray-200 dark:border-white/10 shadow-sm px-4 py-3 rounded-xl flex items-center gap-3">
            <div className="p-2 bg-gray-100 dark:bg-white/5 rounded-lg text-blue-600 dark:text-blue-400">

              <LayoutGrid size={20} />
            </div>
            <div>
              <h2 className="text-sm font-bold text-gray-900 dark:text-white leading-tight">Map Designer</h2>
              <div className="text-[10px] text-slate-500 font-mono flex items-center gap-2">
                <span>EDITING ID: <span className="text-blue-600 font-bold">#{graphId}</span></span>
                {loading && <span className="text-amber-500 animate-pulse">(SYNCING...)</span>}
              </div>
            </div>

            {visualizedPath.length > 0 && (
              <div className="ml-4 px-3 py-1 bg-green-100 border border-green-200 text-green-700 text-xs font-bold rounded-full flex items-center gap-2 animate-in fade-in slide-in-from-top-2">
                <div className="w-2 h-2 bg-green-500 rounded-full animate-pulse" />
                VISUALIZING PATH ({visualizedPath.length} STEPS)
              </div>
            )}
          </div>

          {/* --- LEVEL SELECTOR --- */}
          <div className="mt-2 bg-white/90 dark:bg-[#121214]/90 backdrop-blur border border-gray-200 dark:border-white/10 shadow-sm px-3 py-2 rounded-xl">
            <div className="flex items-center justify-between mb-1.5">
              <span className="text-[10px] font-bold text-slate-500 uppercase tracking-wider flex items-center gap-1">
                <Layers size={10} /> Level Filter
              </span>
              <button
                onClick={() => setShowLevelManager(!showLevelManager)}
                className="text-[10px] text-blue-600 hover:text-blue-800 font-bold"
              >
                {showLevelManager ? 'Close' : 'Manage'}
              </button>
            </div>

            <div className="flex gap-1 flex-wrap">
              <button
                onClick={() => setSelectedLevel(null)}
                className={`px-2.5 py-1 text-[10px] font-bold rounded-full transition-all ${selectedLevel === null
                    ? 'bg-slate-800 text-white shadow-md'
                    : 'bg-gray-100 dark:bg-white/5 text-slate-500 hover:bg-slate-200'
                  }`}
              >
                ALL
              </button>
              {levels.map((level) => (
                <button
                  key={level.id}
                  onClick={() => setSelectedLevel(level.id)}
                  className={`px-2.5 py-1 text-[10px] font-bold rounded-full transition-all ${selectedLevel === level.id
                      ? 'bg-purple-600 text-white shadow-md'
                      : 'bg-purple-50 text-purple-600 hover:bg-purple-100'
                    }`}
                >
                  {level.alias}
                </button>
              ))}
              {levels.length === 0 && (
                <span className="text-[10px] text-gray-500 dark:text-gray-400 italic py-1">No levels defined</span>
              )}
            </div>

            {/* Level Manager */}
            {showLevelManager && (
              <div className="mt-2 pt-2 border-t border-gray-200 dark:border-white/10">
                <div className="flex gap-1 mb-2">
                  <input
                    type="text"
                    placeholder="Alias (L1)"
                    value={newLevelAlias}
                    onChange={(e) => setNewLevelAlias(e.target.value)}
                    className="flex-1 text-[10px] px-2 py-1 border border-slate-300 rounded focus:outline-none focus:border-blue-500"
                  />
                  <input
                    type="number"
                    placeholder="Height"
                    value={newLevelHeight}
                    onChange={(e) => setNewLevelHeight(e.target.value)}
                    className="w-16 text-[10px] px-2 py-1 border border-slate-300 rounded focus:outline-none focus:border-blue-500"
                    step="0.1"
                    min="0"
                  />
                  <button
                    onClick={handleCreateLevel}
                    className="px-2 py-1 bg-purple-600 text-white text-[10px] font-bold rounded hover:bg-purple-700"
                  >
                    <Plus size={10} />
                  </button>
                </div>
                {levels.map((level) => (
                  <div key={level.id} className="flex items-center justify-between py-1 text-[10px]">
                    <span className="font-mono font-bold text-blue-600 dark:text-blue-400">{level.alias}</span>
                    <span className="text-gray-500 dark:text-gray-400">h={level.height}m</span>
                    <button
                      onClick={() => handleDeleteLevel(level.id)}
                      className="text-red-400 hover:text-red-600"
                    >
                      <Trash2 size={10} />
                    </button>
                  </div>
                ))}
              </div>
            )}
          </div>
        </Panel>

        {/* --- RIGHT TOOLBAR --- */}
        <Panel position="top-right" className="m-4 flex flex-col gap-2 items-end">

          {/* NODE PROPERTIES PANEL */}
          {selectedNode && selectedNode.id !== 'map-background' && (
            <div className="bg-white/90 dark:bg-[#121214]/90 backdrop-blur border border-blue-200 shadow-xl rounded-xl p-3 flex flex-col gap-2 w-64 animate-in slide-in-from-right-4">
              <div className="flex items-center gap-2 text-blue-600 border-b border-blue-100 pb-2 mb-1">
                <Edit3 size={14} />
                <span className="text-xs font-bold uppercase">Edit Node Props</span>
              </div>

              {/* Name Input */}
              <div className="flex flex-col gap-1">
                <label className="text-[10px] font-bold text-gray-500 dark:text-gray-400 uppercase">Node Name</label>
                <input
                  type="text"
                  value={selectedNode.data.label}
                  onChange={(e) => updateSelectedNode('label', e.target.value)}
                  className="text-xs border border-slate-300 rounded px-2 py-1 focus:outline-none focus:border-blue-500 font-mono"
                  disabled={selectedNode.data.type === 'depot' || selectedNode.data.type === 'cell'}
                />
              </div>

              {/* Type Select (only for non-depot, non-cell) */}
              {selectedNode.data.type !== 'depot' && selectedNode.data.type !== 'cell' && (
                <div className="flex flex-col gap-1">
                  <label className="text-[10px] font-bold text-gray-500 dark:text-gray-400 uppercase">Node Type</label>
                  <select
                    value={selectedNode.data.type || 'waypoint'}
                    onChange={(e) => updateSelectedNode('type', e.target.value)}
                    className="text-xs border border-slate-300 rounded px-2 py-1 focus:outline-none focus:border-blue-500 bg-white"
                  >
                    <option value="waypoint">Waypoint</option>
                    <option value="conveyor">Conveyor</option>
                    <option value="shelf">Shelf</option>
                  </select>
                </div>
              )}

              {/* Depot indicator */}
              {selectedNode.data.type === 'depot' && (
                <div className="text-[10px] text-red-500 font-bold bg-red-50 px-2 py-1 rounded">
                  ⚠ Depot node — cannot be deleted or renamed
                </div>
              )}

              {/* Cell indicator */}
              {selectedNode.data.type === 'cell' && (
                <div className="text-[10px] text-purple-500 font-bold bg-purple-50 px-2 py-1 rounded">
                  Cell — managed through Shelf panel
                </div>
              )}

              {/* Conveyor Height */}
              {selectedNode.data.type === 'conveyor' && (
                <div className="flex flex-col gap-1">
                  <label className="text-[10px] font-bold text-gray-500 dark:text-gray-400 uppercase flex items-center gap-1">
                    <ArrowUpFromLine size={10} /> Height (m)
                  </label>
                  <input
                    type="number"
                    step="0.1"
                    min="0"
                    value={selectedNode.data.height ?? 1.0}
                    onChange={(e) => updateSelectedNode('height', parseFloat(e.target.value) || 0)}
                    className="text-xs border border-slate-300 rounded px-2 py-1 font-mono focus:outline-none focus:border-blue-500"
                  />
                </div>
              )}

              {/* Shelf: Cell Management */}
              {selectedNode.data.type === 'shelf' && showShelfPanel && (
                <div className="border-t border-gray-200 dark:border-white/10 pt-2 mt-1">
                  <div className="flex items-center justify-between mb-2">
                    <span className="text-[10px] font-bold text-cyan-600 uppercase flex items-center gap-1">
                      <Box size={10} /> Cells in "{selectedNode.data.label}"
                    </span>
                  </div>

                  {/* Existing Cells */}
                  {shelfCells.length === 0 && (
                    <p className="text-[10px] text-gray-500 dark:text-gray-400 italic mb-2">No cells yet</p>
                  )}
                  {shelfCells.map((cell) => (
                    <div key={cell.id} className="flex items-center justify-between py-1 text-[10px] border-b border-slate-50">
                      <span className="font-mono font-bold text-blue-600 dark:text-blue-400">{cell.alias}</span>
                      <span className="text-purple-500 font-bold">{cell.levelAlias || '?'}</span>
                      <button
                        onClick={() => handleDeleteCell(cell.id)}
                        className="text-red-400 hover:text-red-600"
                      >
                        <Trash2 size={10} />
                      </button>
                    </div>
                  ))}

                  {/* Add Cell Form */}
                  {levels.length > 0 ? (
                    <div className="flex gap-1 mt-2">
                      <input
                        type="text"
                        placeholder="Cell alias"
                        value={newCellAlias}
                        onChange={(e) => setNewCellAlias(e.target.value)}
                        className="flex-1 text-[10px] px-2 py-1 border border-slate-300 rounded focus:outline-none focus:border-blue-500"
                      />
                      <select
                        value={newCellLevel}
                        onChange={(e) => setNewCellLevel(e.target.value)}
                        className="text-[10px] px-1 py-1 border border-slate-300 rounded bg-white focus:outline-none focus:border-blue-500"
                      >
                        <option value="">Level</option>
                        {levels.map(l => (
                          <option key={l.id} value={l.id}>{l.alias}</option>
                        ))}
                      </select>
                      <button
                        onClick={handleCreateCell}
                        className="px-2 py-1 bg-cyan-600 text-white text-[10px] font-bold rounded hover:bg-cyan-700"
                      >
                        <Plus size={10} />
                      </button>
                    </div>
                  ) : (
                    <p className="text-[10px] text-amber-500 mt-2">Create levels first before adding cells</p>
                  )}
                </div>
              )}
            </div>
          )}

          {/* GLOBAL TOOLS BUTTONS */}
          <div className="bg-white/90 dark:bg-[#121214]/90 backdrop-blur border border-gray-200 dark:border-white/10 shadow-lg rounded-xl p-1.5 flex gap-1">
            <div className="flex gap-1 pr-2 border-r border-gray-200 dark:border-white/10 items-center">

              {/* Map Controls */}
              {bgUrl && (
                <>
                  <button onClick={handleRemoveBackground} className="p-2 text-red-400 hover:text-red-600 hover:bg-red-50 rounded-lg transition-all" title="Remove Map">
                    <XCircle size={18} />
                  </button>
                  <button onClick={() => setMapLocked(!mapLocked)} className={`p-2 rounded-lg transition-all ${!mapLocked ? 'bg-amber-100 text-amber-600 shadow-sm' : 'text-slate-500 hover:text-blue-600 hover:bg-blue-50'}`} title={mapLocked ? "Unlock Map for Editing" : "Unlock Map"}>
                    {mapLocked ? <Lock size={18} /> : <Unlock size={18} />}
                  </button>
                </>
              )}

              <label className="cursor-pointer p-2 text-slate-500 hover:text-blue-600 hover:bg-blue-50 rounded-lg transition-all group relative" title="Upload Map">
                <input type="file" accept="image/*" className="hidden" onChange={handleFileUpload} />
                <Upload size={18} />
              </label>

              {/* Tool Switcher */}
              <button
                onClick={() => setToolMode('move')}
                className={`p-2 rounded-lg transition-all ${toolMode === 'move'
                    ? 'bg-blue-600 text-white shadow-md'
                    : 'text-slate-500 hover:text-blue-600 hover:bg-blue-50'
                  }`}
                title="Move Tool"
              >
                <MousePointer2 size={18} />
              </button>

              <button
                onClick={() => setToolMode('connect')}
                className={`p-2 rounded-lg transition-all ${toolMode === 'connect'
                    ? 'bg-blue-600 text-white shadow-md'
                    : 'text-slate-500 hover:text-blue-600 hover:bg-blue-50'
                  }`}
                title="Connect Tool"
              >
                <LinkIcon size={18} />
              </button>

              {/* Add Node — dropdown */}
              <div className="relative">
                <button
                  onClick={() => setShowAddMenu(!showAddMenu)}
                  className="p-2 text-slate-500 hover:text-blue-600 hover:bg-blue-50 rounded-lg transition-all flex items-center gap-0.5"
                  title="Add Node"
                >
                  <PlusCircle size={18} />
                  <ChevronDown size={10} />
                </button>
                {showAddMenu && (
                  <div className="absolute top-full right-0 mt-1 bg-white dark:bg-[#121214] border border-gray-200 dark:border-white/10 rounded-lg shadow-xl py-1 z-50 w-36">
                    <button
                      onClick={() => { addNode('waypoint'); setShowAddMenu(false); }}
                      className="w-full px-3 py-2 text-left text-xs hover:bg-gray-50 dark:bg-[#09090b] text-gray-900 dark:text-white transition-colors flex items-center gap-2"
                    >
                      <CircleDot size={12} className="text-blue-600 dark:text-blue-400" /> Waypoint
                    </button>
                    <button
                      onClick={() => { addNode('conveyor'); setShowAddMenu(false); }}
                      className="w-full px-3 py-2 text-left text-xs hover:bg-gray-50 dark:bg-[#09090b] text-gray-900 dark:text-white transition-colors flex items-center gap-2"
                    >
                      <ArrowUpFromLine size={12} className="text-amber-600" /> Conveyor
                    </button>
                    <button
                      onClick={() => { addNode('shelf'); setShowAddMenu(false); }}
                      className="w-full px-3 py-2 text-left text-xs hover:bg-gray-50 dark:bg-[#09090b] text-gray-900 dark:text-white transition-colors flex items-center gap-2"
                    >
                      <Box size={12} className="text-cyan-600" /> Shelf
                    </button>
                  </div>
                )}
              </div>

              <button
                onMouseDown={(e) => { e.preventDefault(); handleDelete(); }}
                className="p-2 text-slate-500 hover:text-red-600 hover:bg-red-50 rounded-lg transition-all"
                title="Delete Selected"
              >
                <Trash2 size={18} />
              </button>
            </div>

            {/* Sync Actions */}
            <div className="flex gap-1 pl-1">
              <button
                onClick={reloadGraph}
                className="p-2 text-gray-500 dark:text-gray-400 hover:text-blue-600 dark:text-blue-400 hover:bg-gray-100 dark:bg-white/5 rounded-lg transition-all"
                title="Reload"
              >
                <RefreshCw size={18} className={loading ? 'animate-spin' : ''} />
              </button>

              <button
                onClick={async () => {
                  const success = await saveGraph(allNodes, edges, bgUrl);
                  if (success) await reloadGraph();
                }}
                className="flex items-center gap-2 px-3 py-1.5 bg-slate-800 text-white text-xs font-bold rounded-lg hover:bg-slate-700 shadow-md transition-all active:translate-y-0.5"
              >
                <Save size={14} />
                <span>SAVE</span>
              </button>
            </div>
          </div>
        </Panel>

        {/* --- BOTTOM STATUS BAR --- */}
        <Panel position="bottom-center" className="mb-2">
          <div className="bg-slate-800/90 backdrop-blur text-slate-300 text-[10px] font-mono px-4 py-1.5 rounded-full flex gap-4 shadow-lg border border-gray-300 dark:border-white/10">
            <span>MODE: <span className="text-white font-bold">{toolMode.toUpperCase()}</span></span>
            <span className="text-blue-600 dark:text-blue-400">|</span>
            <span>NODES: {nodes.filter((n) => n.id !== 'map-background').length}</span>
            <span className="text-blue-600 dark:text-blue-400">|</span>
            <span>EDGES: {edges.length}</span>
            {selectedLevel !== null && (
              <>
                <span className="text-blue-600 dark:text-blue-400">|</span>
                <span>LEVEL: <span className="text-purple-400 font-bold">{levels.find(l => l.id === selectedLevel)?.alias || '?'}</span></span>
              </>
            )}
          </div>
        </Panel>

        <Controls />
        <MiniMap
          className="!bg-gray-100 dark:bg-white/5 border border-slate-300 rounded-lg"
          nodeColor={(n) => {
            const type = n.data?.type || 'waypoint';
            if (type === 'shelf') return '#0891b2';
            if (type === 'conveyor') return '#d97706';
            if (type === 'cell') return '#a855f7';
            if (type === 'depot') return '#dc2626';
            return '#475569';
          }}
        />
      </ReactFlow>
    </div>
  );
};

export default GraphEditor;
