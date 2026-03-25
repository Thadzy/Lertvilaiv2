import { useState, useCallback } from 'react';
import { type Node, type Edge, MarkerType } from 'reactflow';
import { supabase } from '../lib/supabaseClient';

const SCALE_FACTOR = 100;

// ============================================
// TYPE DEFINITIONS (matching DB schema views)
// ============================================

/** Row from wh_nodes_view */
export interface ViewNode {
  id: number;
  type: 'waypoint' | 'conveyor' | 'shelf' | 'cell' | 'depot';
  alias: string | null;
  graph_id: number;
  x: number;
  y: number;
  height: number | null;   // conveyor-specific
  shelf_id: number | null; // cell-specific
  level_id: number | null; // cell-specific
  created_at: string;
}

/** Row from wh_edges_view */
export interface ViewEdge {
  edge_id: number;
  graph_id: number;
  node_a_id: number;
  node_b_id: number;
  node_a_type: string;
  node_a_alias: string | null;
  node_b_type: string;
  node_b_alias: string | null;
  distance_2d: number;
}

/** Level row from wh_levels */
export interface Level {
  id: number;
  alias: string;
  height: number;
  graph_id: number;
  cell_count?: number;
  created_at: string;
}

// ============================================
// HOOK: useGraphData
// ============================================
export const useGraphData = (graphId: number) => {
  const [loading, setLoading] = useState(false);

  // =========================================================
  // 1. READ OPERATION (FETCH MAP) - Using Views
  // =========================================================
  const loadGraph = useCallback(async () => {
    if (!graphId) return { nodes: [], edges: [], mapUrl: null, levels: [] as Level[] };

    setLoading(true);
    try {
      // Get Graph metadata
      const { data: graphData, error: graphError } = await supabase
        .from('wh_graphs')
        .select('*')
        .eq('id', graphId)
        .single();

      if (graphError || !graphData) throw new Error('Graph not found');

      // Get Nodes from VIEW (denormalized with coordinates)
      const { data: nodeData, error: nodeError } = await supabase
        .from('wh_nodes_view')
        .select('*')
        .eq('graph_id', graphId);

      if (nodeError) throw nodeError;

      // Get Edges from VIEW
      const { data: edgeData, error: edgeError } = await supabase
        .from('wh_edges_view')
        .select('edge_id, graph_id, node_a_id, node_b_id')
        .eq('graph_id', graphId);

      if (edgeError) throw edgeError;

      // Get Levels
      const { data: levelData, error: levelError } = await supabase
        .from('wh_levels')
        .select('*')
        .eq('graph_id', graphId)
        .order('height', { ascending: true });

      if (levelError) throw levelError;

      const levels: Level[] = (levelData || []) as Level[];

      // Build a lookup: shelf ID → shelf position (for cell offset)
      const viewNodes = nodeData as ViewNode[];
      const shelfPositions = new Map<number, { x: number; y: number }>();
      viewNodes.forEach(n => {
        if (n.type === 'shelf') {
          shelfPositions.set(n.id, { x: n.x, y: n.y });
        }
      });

      // Count cells per shelf for offset calculation
      const cellsByShelf = new Map<number, number>();
      viewNodes.forEach(n => {
        if (n.type === 'cell' && n.shelf_id !== null) {
          cellsByShelf.set(n.shelf_id, (cellsByShelf.get(n.shelf_id) || 0) + 1);
        }
      });

      // Track cell index per shelf for positioning
      const cellIndexByShelf = new Map<number, number>();

      // Transform Nodes
      const flowNodes: Node[] = viewNodes.map((n) => {
        let posX = n.x * SCALE_FACTOR;
        let posY = n.y * SCALE_FACTOR;
        let draggable = true;

        // Cells: position offset from parent shelf, not draggable
        if (n.type === 'cell' && n.shelf_id !== null) {
          const shelfPos = shelfPositions.get(n.shelf_id);
          if (shelfPos) {
            const cellIdx = cellIndexByShelf.get(n.shelf_id) || 0;
            cellIndexByShelf.set(n.shelf_id, cellIdx + 1);
            // Arrange cells in a small arc below their shelf
            const angle = -Math.PI / 2 + (cellIdx * Math.PI / 4) - (((cellsByShelf.get(n.shelf_id) || 1) - 1) * Math.PI / 8);
            const radius = 50; // px offset from shelf center
            posX = shelfPos.x * SCALE_FACTOR + Math.cos(angle) * radius;
            posY = shelfPos.y * SCALE_FACTOR + Math.sin(angle) * radius + 40;
          }
          draggable = false;
        }

        // Depot: not deletable
        if (n.type === 'depot') {
          draggable = true; // can move depot
        }

        // Find level alias for cells
        let levelAlias: string | null = null;
        if (n.type === 'cell' && n.level_id !== null) {
          const lvl = levels.find(l => l.id === n.level_id);
          levelAlias = lvl ? lvl.alias : null;
        }

        return {
          id: n.id.toString(),
          type: 'waypointNode', // custom node component name
          position: { x: posX, y: posY },
          draggable,
          data: {
            label: n.alias || `Node_${n.id}`,
            type: n.type,
            height: n.height,        // conveyor height
            shelf_id: n.shelf_id,    // cell → parent shelf
            level_id: n.level_id,    // cell → level
            levelAlias,              // e.g. "L1" for display
          },
        };
      });

      // Background Image
      const mapUrl = graphData.map_url;
      if (mapUrl) {
        let mapX = 0, mapY = 0, mapW = 1200, mapH = 800;
        let cleanUrl = mapUrl;

        if (mapUrl.includes('#')) {
          const [base, hash] = mapUrl.split('#');
          cleanUrl = base;
          const params = new URLSearchParams(hash);
          if (params.has('x')) mapX = parseFloat(params.get('x') || '0');
          if (params.has('y')) mapY = parseFloat(params.get('y') || '0');
          if (params.has('w')) mapW = parseFloat(params.get('w') || '1200');
          if (params.has('h')) mapH = parseFloat(params.get('h') || '800');
        }

        flowNodes.unshift({
          id: 'map-background',
          type: 'mapNode',
          position: { x: mapX, y: mapY },
          data: { url: cleanUrl },
          style: {
            width: mapW,
            height: mapH,
            zIndex: -11,
          },
          draggable: false,
          selectable: false,
        });
      }

      // Transform Edges
      const flowEdges: Edge[] = (edgeData as ViewEdge[]).map((e) => ({
        id: `e${e.node_a_id}-${e.node_b_id}`,
        source: e.node_a_id.toString(),
        target: e.node_b_id.toString(),
        type: 'straight',
        animated: true,
        style: { stroke: '#3b82f6', strokeWidth: 2, strokeDasharray: '5,5' },
        markerEnd: { type: MarkerType.ArrowClosed, color: '#3b82f6' },
      }));

      return { nodes: flowNodes, edges: flowEdges, mapUrl, levels };

    } catch (error: unknown) {
      console.error('[useGraphData] Error loading graph:', error);
      return { nodes: [], edges: [], mapUrl: null, levels: [] as Level[] };
    } finally {
      setLoading(false);
    }
  }, [graphId]);

  // =========================================================
  // 2. WRITE OPERATION (SAVE MAP) - Using RPC Functions
  // =========================================================
  const saveGraph = useCallback(async (nodes: Node[], edges: Edge[], currentMapUrl: string | null = null) => {
    if (!graphId) {
      alert("Error: No graph ID loaded. Cannot save.");
      return false;
    }
    setLoading(true);

    try {
      const idMap = new Map<string, number>();

      // Separate nodes
      const activeNodes = nodes.filter(n => n.id !== 'map-background');
      const existingNodes: { flowNode: Node; dbId: number }[] = [];
      const newNodes: Node[] = [];
      const nodesToDelete: number[] = [];

      for (const n of activeNodes) {
        // Skip cell nodes — they are managed through shelf panel, not canvas drag
        if (n.data?.type === 'cell') {
          const numericId = Number(n.id);
          if (!isNaN(numericId)) {
            idMap.set(n.id, numericId);
          }
          continue;
        }

        const numericId = Number(n.id);
        const isNewNode = isNaN(numericId);

        if (isNewNode) {
          newNodes.push(n);
        } else {
          existingNodes.push({ flowNode: n, dbId: numericId });
          idMap.set(n.id, numericId);
        }
      }

      // -----------------------------------------------
      // A. Determine nodes to delete
      // -----------------------------------------------
      const { data: currentDbNodes } = await supabase
        .from('wh_nodes_view')
        .select('id, type')
        .eq('graph_id', graphId);

      // Build a map of DB id → DB type for type-change detection
      const dbTypeMap = new Map<number, string>();
      if (currentDbNodes) {
        currentDbNodes.forEach(n => dbTypeMap.set(n.id, n.type));

        const activeDbIds = new Set(existingNodes.map(n => n.dbId));
        // Also include cell IDs we skipped above
        activeNodes.forEach(n => {
          const numId = Number(n.id);
          if (!isNaN(numId)) activeDbIds.add(numId);
        });

        for (const dbNode of currentDbNodes) {
          if (dbNode.type === 'depot' || dbNode.type === 'cell') continue;
          if (!activeDbIds.has(dbNode.id)) {
            nodesToDelete.push(dbNode.id);
          }
        }
      }

      // Detect type-changed nodes: remove from existingNodes, treat as delete+recreate
      const typeChangedNodes: Node[] = [];
      const stableExistingNodes = existingNodes.filter(({ flowNode, dbId }) => {
        const dbType = dbTypeMap.get(dbId);
        const canvasType = flowNode.data?.type as string;
        if (dbType && dbType !== 'depot' && dbType !== 'cell' && canvasType && canvasType !== dbType) {
          console.log(`[saveGraph] Type change detected: node ${dbId} ${dbType} → ${canvasType}`);
          nodesToDelete.push(dbId);
          typeChangedNodes.push(flowNode);
          return false;
        }
        return true;
      });
      // Reassign existingNodes to only stable ones
      existingNodes.length = 0;
      stableExistingNodes.forEach(n => existingNodes.push(n));
      // Add type-changed nodes to newNodes so they get recreated
      newNodes.push(...typeChangedNodes);

      console.log('[saveGraph] newNodes:', newNodes.length, '| existingNodes:', existingNodes.length);

      // -----------------------------------------------
      // B. Delete removed nodes
      // -----------------------------------------------
      console.log('[saveGraph] B. nodesToDelete:', nodesToDelete);
      for (const nodeId of nodesToDelete) {
        const { error } = await supabase.rpc('wh_delete_node', { p_node_id: nodeId });
        if (error) {
          console.error(`[saveGraph] B. Failed to delete node ${nodeId}:`, error.message);
        }
      }

      // -----------------------------------------------
      // C. Update existing node positions
      // -----------------------------------------------
      for (const { flowNode, dbId } of existingNodes) {
        const x = flowNode.position.x / SCALE_FACTOR;
        const y = flowNode.position.y / SCALE_FACTOR;

        const { error } = await supabase.rpc('wh_update_node_position', {
          p_node_id: dbId,
          p_x: x,
          p_y: y
        });

        if (error) {
          if (!error.message.includes('cell')) {
            console.error(`[useGraphData] Failed to update node ${dbId}:`, error.message);
          }
        }
      }

      // -----------------------------------------------
      // D. Create new nodes via RPC
      // -----------------------------------------------
      console.log('[saveGraph] D. Creating', newNodes.length, 'new nodes...');
      for (const flowNode of newNodes) {
        const nodeType = (flowNode.data.type || 'waypoint') as string;
        const x = flowNode.position.x / SCALE_FACTOR;
        const y = flowNode.position.y / SCALE_FACTOR;
        const alias = flowNode.data.label || null;

        let newNodeId: number | null = null;

        try {
          if (nodeType === 'waypoint') {
            const { data, error } = await supabase.rpc('wh_create_waypoint', {
              p_graph_id: graphId, p_x: x, p_y: y, p_alias: alias
            });
            if (error) throw error;
            newNodeId = data;

          } else if (nodeType === 'shelf') {
            const { data, error } = await supabase.rpc('wh_create_shelf', {
              p_graph_id: graphId, p_x: x, p_y: y, p_alias: alias
            });
            if (error) throw error;
            newNodeId = data;

          } else if (nodeType === 'conveyor') {
            const height = flowNode.data.height ?? 1.0;
            const { data, error } = await supabase.rpc('wh_create_conveyor', {
              p_graph_id: graphId, p_x: x, p_y: y, p_height: height, p_alias: alias
            });
            if (error) throw error;
            newNodeId = data;

          } else if (nodeType === 'depot') {
            const { data: depotId } = await supabase.rpc('wh_get_depot_node_id', {
              p_graph_id: graphId
            });
            if (depotId) {
              await supabase.rpc('wh_update_node_position', {
                p_node_id: depotId, p_x: x, p_y: y
              });
              newNodeId = depotId;
            }

          } else {
            console.warn(`[useGraphData] Unknown type '${nodeType}', creating as waypoint`);
            const { data, error } = await supabase.rpc('wh_create_waypoint', {
              p_graph_id: graphId, p_x: x, p_y: y, p_alias: alias
            });
            if (error) throw error;
            newNodeId = data;
          }

          if (newNodeId !== null) {
            idMap.set(flowNode.id, newNodeId);
          }

        } catch (err: unknown) {
          const msg = err instanceof Error ? err.message : String(err);
          console.error(`[saveGraph] D. Failed to create node '${alias}':`, msg);
        }
      }

      // -----------------------------------------------
      // E. Sync Edges: Delete non-cell edges, then recreate
      // -----------------------------------------------
      const { data: currentEdges } = await supabase
        .from('wh_edges_view')
        .select('edge_id, node_a_id, node_b_id, node_a_type, node_b_type')
        .eq('graph_id', graphId);

      console.log('[saveGraph] E. currentEdges in DB:', currentEdges?.length ?? 0, '| edges in canvas:', edges.length);
      if (currentEdges) {
        for (const edge of currentEdges) {
          // Skip shelf→cell edges — they are auto-managed by wh_create_cell and must not be deleted
          if (edge.node_a_type === 'cell' || edge.node_b_type === 'cell') continue;
          const { error } = await supabase.rpc('wh_delete_edge', { p_edge_id: edge.edge_id });
          if (error) {
            console.error(`[saveGraph] E. Edge delete failed:`, error.message);
          }
        }
      }

      for (const edge of edges) {
        const sourceId = idMap.get(edge.source);
        const targetId = idMap.get(edge.target);

        if (sourceId === undefined || targetId === undefined) {
          console.warn(`[useGraphData] Skipping edge - missing node mapping for ${edge.source} -> ${edge.target}`);
          continue;
        }

        const { error } = await supabase.rpc('wh_create_edge', {
          p_graph_id: graphId,
          p_node_a_id: sourceId,
          p_node_b_id: targetId
        });

        if (error) {
          if (!error.message.includes('cell') && !error.message.includes('already exists')) {
            console.error(`[saveGraph] E. Failed to create edge ${sourceId}->${targetId}:`, error.message);
          }
        }
      }

      // -----------------------------------------------
      // F. Save Map Background Transform
      // -----------------------------------------------
      const mapNode = nodes.find(n => n.id === 'map-background');
      if (mapNode && currentMapUrl) {
        console.log('[useGraphData] Found map-background node, checking for changes...');
        try {
          const baseUrl = currentMapUrl.split('#')[0];
          const x = Math.round(mapNode.position.x * 10) / 10;
          const y = Math.round(mapNode.position.y * 10) / 10;
          
          // Handle both string ("100px") and number types
          const getVal = (val: any) => {
            if (typeof val === 'number') return val;
            if (typeof val === 'string') return parseFloat(val);
            return 0;
          };

          const w = Math.round(getVal(mapNode.width || mapNode.style?.width || mapNode.data?.width || 1200));
          const h = Math.round(getVal(mapNode.height || mapNode.style?.height || mapNode.data?.height || 800));
          
          const newHash = `x=${x}&y=${y}&w=${w}&h=${h}`;
          const newMapUrl = `${baseUrl}#${newHash}`;
          
          if (newMapUrl !== currentMapUrl) {
            console.log(`[useGraphData] Map transform changed. Updating DB: ${newHash}`);
            const { error: mapUpdateError } = await supabase
              .from('wh_graphs')
              .update({ map_url: newMapUrl })
              .eq('id', graphId);
            
            if (mapUpdateError) {
              console.error('[useGraphData] Error updating map transform:', mapUpdateError.message);
            }
          } else {
            console.log('[useGraphData] Map transform has not changed.');
          }
        } catch (err) {
          console.warn(`[useGraphData] Failed to parse or save map node transform:`, err);
        }
      } else {
        console.log('[useGraphData] No map-background node or currentMapUrl found during save.', { hasNode: !!mapNode, hasUrl: !!currentMapUrl });
      }

      alert("Map saved successfully!");
      return true;

    } catch (error: unknown) {
      console.error('[useGraphData] Error saving map:', error);
      const msg = error instanceof Error ? error.message : 'Unknown error';
      alert(`Save failed: ${msg}`);
      return false;
    } finally {
      setLoading(false);
    }
  }, [graphId]);

  // =========================================================
  // 3. LEVEL MANAGEMENT
  // =========================================================
  const createLevel = useCallback(async (alias: string, height: number) => {
    try {
      const { data, error } = await supabase.rpc('wh_create_level', {
        p_graph_id: graphId,
        p_alias: alias,
        p_height: height,
      });
      if (error) throw error;
      return data as number;
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error('[useGraphData] Failed to create level:', msg);
      alert(`Failed to create level: ${msg}`);
      return null;
    }
  }, [graphId]);

  const deleteLevel = useCallback(async (levelId: number) => {
    try {
      const { error } = await supabase
        .from('wh_levels')
        .delete()
        .eq('id', levelId);
      if (error) throw error;
      return true;
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error('[useGraphData] Failed to delete level:', msg);
      alert(`Failed to delete level: ${msg}`);
      return false;
    }
  }, []);

  // =========================================================
  // 4. CELL MANAGEMENT (via shelf)
  // =========================================================
  const createCell = useCallback(async (shelfAlias: string, levelAlias: string, cellAlias: string) => {
    try {
      const { data, error } = await supabase.rpc('wh_create_cell', {
        p_graph_id: graphId,
        p_shelf_alias: shelfAlias,
        p_level_alias: levelAlias,
        p_alias: cellAlias,
      });
      if (error) throw error;
      return data as number;
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error('[useGraphData] Failed to create cell:', msg);
      alert(`Failed to create cell: ${msg}`);
      return null;
    }
  }, [graphId]);

  const deleteCell = useCallback(async (cellId: number) => {
    try {
      const { error } = await supabase.rpc('wh_delete_node', { p_node_id: cellId });
      if (error) throw error;
      return true;
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error('[useGraphData] Failed to delete cell:', msg);
      alert(`Failed to delete cell: ${msg}`);
      return false;
    }
  }, []);

  return { loadGraph, saveGraph, loading, createLevel, deleteLevel, createCell, deleteCell };
};
