BEGIN;

-- Denormalized view of all nodes with their coordinates and type-specific attributes
-- Makes it easy to query all nodes regardless of type
CREATE OR REPLACE VIEW public.wh_nodes_view AS
  -- Depot nodes
  SELECT
    n.id,
    n.type,
    n.alias,
    n.tag_id,
    n.graph_id,
    d.x,
    d.y,
    NULL::real AS height,  -- conveyor-specific
    NULL::bigint AS shelf_id,  -- cell-specific
    NULL::bigint AS level_id,  -- cell-specific
    n.created_at
  FROM public.wh_nodes n
  JOIN public.wh_depot_nodes d ON d.id = n.id

  UNION ALL

  -- Waypoint nodes
  SELECT
    n.id,
    n.type,
    n.alias,
    n.tag_id,
    n.graph_id,
    w.x,
    w.y,
    NULL::real AS height,
    NULL::bigint AS shelf_id,
    NULL::bigint AS level_id,
    n.created_at
  FROM public.wh_nodes n
  JOIN public.wh_waypoint_nodes w ON w.id = n.id

  UNION ALL

  -- Conveyor nodes
  SELECT
    n.id,
    n.type,
    n.alias,
    n.tag_id,
    n.graph_id,
    c.x,
    c.y,
    c.height,
    NULL::bigint AS shelf_id,
    NULL::bigint AS level_id,
    n.created_at
  FROM public.wh_nodes n
  JOIN public.wh_conveyor_nodes c ON c.id = n.id

  UNION ALL

  -- Shelf nodes
  SELECT
    n.id,
    n.type,
    n.alias,
    n.tag_id,
    n.graph_id,
    s.x,
    s.y,
    NULL::real AS height,
    NULL::bigint AS shelf_id,
    NULL::bigint AS level_id,
    n.created_at
  FROM public.wh_nodes n
  JOIN public.wh_shelf_nodes s ON s.id = n.id

  UNION ALL

  -- Cell nodes (inherits x,y from shelf, height from level)
  SELECT
    n.id,
    n.type,
    n.alias,
    n.tag_id,
    n.graph_id,
    s.x,
    s.y,
    lv.height AS height,
    cn.shelf_id,
    cn.level_id,
    n.created_at
  FROM public.wh_nodes n
  JOIN public.wh_cell_nodes cn ON cn.id = n.id
  JOIN public.wh_shelf_nodes s ON s.id = cn.shelf_id
  JOIN public.wh_levels lv ON lv.id = cn.level_id;

-- Optional: View with level details for cells
CREATE OR REPLACE VIEW public.wh_nodes_detailed_view AS
  SELECT
    nv.*,
    lv.alias AS level_alias,
    lv.height AS level_height
  FROM public.wh_nodes_view nv
  LEFT JOIN public.wh_levels lv ON lv.id = nv.level_id;

-- Edges with node details for both endpoints
-- Useful for displaying edge connections with node names and types
CREATE OR REPLACE VIEW public.wh_edges_view AS
  SELECT
    e.id AS edge_id,
    e.graph_id,
    e.node_a_id,
    e.node_b_id,
    -- Node A details
    na.type AS node_a_type,
    na.alias AS node_a_alias,
    nva.x AS node_a_x,
    nva.y AS node_a_y,
    -- Node B details
    nb.type AS node_b_type,
    nb.alias AS node_b_alias,
    nvb.x AS node_b_x,
    nvb.y AS node_b_y,
    -- Edge metadata
    e.created_at,
    -- Calculated: Euclidean distance (2D)
    sqrt(
      power(nva.x - nvb.x, 2) +
      power(nva.y - nvb.y, 2)
    )::real AS distance_2d
  FROM public.wh_edges e
  JOIN public.wh_nodes na ON na.id = e.node_a_id
  JOIN public.wh_nodes nb ON nb.id = e.node_b_id
  JOIN public.wh_nodes_view nva ON nva.id = e.node_a_id
  JOIN public.wh_nodes_view nvb ON nvb.id = e.node_b_id;

-- Graph summary with statistics per graph
-- Shows node counts by type, edge count, and level count
CREATE OR REPLACE VIEW public.wh_graph_summary_view AS
  SELECT
    g.id AS graph_id,
    g.name AS graph_name,
    g.map_url,
    g.map_res,
    -- Node counts by type
    COUNT(DISTINCT CASE WHEN n.type = 'depot' THEN n.id END) AS depot_count,
    COUNT(DISTINCT CASE WHEN n.type = 'waypoint' THEN n.id END) AS waypoint_count,
    COUNT(DISTINCT CASE WHEN n.type = 'conveyor' THEN n.id END) AS conveyor_count,
    COUNT(DISTINCT CASE WHEN n.type = 'shelf' THEN n.id END) AS shelf_count,
    COUNT(DISTINCT CASE WHEN n.type = 'cell' THEN n.id END) AS cell_count,
    COUNT(DISTINCT n.id) AS total_node_count,
    -- Edge and level counts
    COUNT(DISTINCT e.id) AS edge_count,
    COUNT(DISTINCT l.id) AS level_count,
    -- Timestamps
    g.created_at AS graph_created_at,
    MAX(n.created_at) AS last_node_created_at,
    MAX(e.created_at) AS last_edge_created_at
  FROM public.wh_graphs g
  LEFT JOIN public.wh_nodes n ON n.graph_id = g.id
  LEFT JOIN public.wh_edges e ON e.graph_id = g.id
  LEFT JOIN public.wh_levels l ON l.graph_id = g.id
  GROUP BY g.id, g.name, g.map_url, g.map_res, g.created_at;

COMMIT;
