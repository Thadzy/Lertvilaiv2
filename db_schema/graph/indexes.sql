BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS wh_nodes_one_depot_per_graph_uidx
ON public.wh_nodes (graph_id) WHERE type='depot';

-- Undirected uniqueness per graph via UNIQUE EXPRESSION INDEX
CREATE UNIQUE INDEX IF NOT EXISTS wh_edges_undirected_unique_idx
ON public.wh_edges (
  graph_id,
  LEAST(node_a_id, node_b_id),
  GREATEST(node_a_id, node_b_id)
);

-- Performance indexes for A* cost matrix queries
-- These indexes significantly improve query performance when filtering by graph_id and node IDs
CREATE INDEX IF NOT EXISTS wh_edges_graph_node_a_idx
ON public.wh_edges (graph_id, node_a_id);

CREATE INDEX IF NOT EXISTS wh_edges_graph_node_b_idx
ON public.wh_edges (graph_id, node_b_id);

-- For faster query after A*
CREATE INDEX IF NOT EXISTS wh_nodes_graph_id_idx
ON public.wh_nodes (graph_id);

COMMIT;
