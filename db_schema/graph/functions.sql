BEGIN;

-- ============================================================================
-- WAREHOUSE GRAPH API FUNCTIONS
-- ============================================================================
--
-- This file contains all API functions for warehouse graph management:
-- - Creation functions (SECURITY DEFINER) for nodes, edges, levels
-- - Query functions for lookup and listing
-- - Update functions for node positions
-- - Delete functions with validation
-- - Routing functions using pgRouting A*
--
-- USAGE EXAMPLES:
-- ============================================================================
--
-- Example 1: Create a complete graph with routing
-- -----------------------------------------------------------------------------
-- INSERT INTO wh_graphs (name) VALUES ('warehouse_main') RETURNING id;
-- -- Returns: 1 (depot auto-created)
--
-- SELECT wh_create_level(1, 'ground', 0.0);
-- SELECT wh_create_waypoint(1, 5.0, 5.0, 'entrance');
-- SELECT wh_create_shelf(1, 10.0, 5.0, 'shelf_A');
-- SELECT wh_create_cell(1,
--   (SELECT id FROM wh_nodes WHERE alias='shelf_A'),
--   (SELECT id FROM wh_levels WHERE alias='ground'),
--   'cell_A1');
--
-- SELECT wh_create_edge(1,
--   (SELECT id FROM wh_nodes WHERE alias='entrance'),
--   (SELECT id FROM wh_nodes WHERE alias='shelf_A'));
--
--
-- Example 2: Calculate shortest path
-- -----------------------------------------------------------------------------
-- SELECT wh_astar_shortest_path(
--   1,  -- graph_id
--   (SELECT id FROM wh_nodes WHERE alias='entrance'),
--   (SELECT id FROM wh_nodes WHERE alias='cell_A1')
-- );
-- -- Returns: {4, 5, 6}  (array of node IDs)
--
--
-- Example 3: Get cost matrix for multiple nodes (TSP/VRP)
-- -----------------------------------------------------------------------------
-- SELECT * FROM wh_astar_cost_matrix(
--   1,  -- graph_id
--   ARRAY[
--     (SELECT id FROM wh_nodes WHERE alias='entrance'),
--     (SELECT id FROM wh_nodes WHERE alias='cell_A1'),
--     (SELECT id FROM wh_nodes WHERE alias='cell_A2'),
--     (SELECT id FROM wh_nodes WHERE alias='shelf_B')
--   ]
-- );
-- -- Returns: TABLE(start_vid, end_vid, agg_cost)
--
--
-- Example 4: Query graph statistics
-- -----------------------------------------------------------------------------
-- SELECT * FROM wh_graph_summary_view WHERE graph_id = 1;
-- -- Returns: node counts by type, edge count, timestamps
--
-- SELECT * FROM wh_nodes_view WHERE graph_id = 1 ORDER BY type, id;
-- -- Returns: all nodes with coordinates
--
-- SELECT * FROM wh_edges_view WHERE graph_id = 1;
-- -- Returns: edges with endpoint details
--
--
-- Example 5: Update and delete operations
-- -----------------------------------------------------------------------------
-- -- Move a waypoint
-- SELECT wh_update_node_position(
--   (SELECT id FROM wh_nodes WHERE alias='entrance'),
--   6.0, 6.0
-- );
--
-- -- Delete a node (cascade deletes edges)
-- SELECT wh_delete_node(
--   (SELECT id FROM wh_nodes WHERE alias='old_waypoint')
-- );
--
-- -- Delete an edge
-- SELECT wh_delete_edge_by_nodes(node_a_id, node_b_id);
--
--
-- SECURITY NOTES:
-- ============================================================================
-- - All creation/update/delete functions use SECURITY DEFINER
-- - Grant EXECUTE on functions to application roles
-- - Revoke direct table access from application roles
-- - Functions validate all inputs and prevent cross-graph contamination
-- - See README.md for recommended permission model
--
-- ============================================================================

-- APPLICATION Functions
-- create a waypoint (wh_nodes + wh_waypoint_nodes) atomically
-- - Validates graph exists
-- - Optional alias (enforced unique per graph by existing constraint)
-- - Returns the created node id
-- - Uses SECURITY DEFINER so you can grant EXECUTE to app role while revoking table writes
CREATE OR REPLACE FUNCTION public.wh_create_waypoint(
  p_graph_id bigint,
  p_x        real,
  p_y        real,
  p_alias    text DEFAULT NULL,
  p_tag_id   text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id bigint;
BEGIN
  -- Validate graph exists
  IF NOT EXISTS (
    SELECT 1 FROM public.wh_graphs g WHERE g.id = p_graph_id
  ) THEN
    RAISE EXCEPTION 'Graph % does not exist', p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Create parent node
  INSERT INTO public.wh_nodes (type, alias, tag_id, graph_id)
  VALUES ('waypoint', p_alias, p_tag_id, p_graph_id)
  RETURNING id INTO v_id;

  -- Create subtype row
  INSERT INTO public.wh_waypoint_nodes (id, x, y)
  VALUES (v_id, p_x, p_y);

  RETURN v_id;

EXCEPTION
  WHEN unique_violation THEN
    -- Most likely UNIQUE(graph_id, alias) in wh_nodes
    RAISE EXCEPTION 'Alias "%" already exists in graph %', p_alias, p_graph_id
      USING ERRCODE = 'unique_violation';
END;
$$;

-- create a conveyor (wh_nodes + wh_conveyor_nodes) atomically
-- - Validates graph exists
-- - Optional alias (unique per graph enforced by wh_nodes constraint)
-- - Returns the created node id
-- - SECURITY DEFINER lets you grant EXECUTE while revoking table writes

CREATE OR REPLACE FUNCTION public.wh_create_conveyor(
  p_graph_id bigint,
  p_x        real,
  p_y        real,
  p_height   real,
  p_alias    text DEFAULT NULL,
  p_tag_id   text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id bigint;
BEGIN
  -- Validate graph exists
  IF NOT EXISTS (
    SELECT 1 FROM public.wh_graphs g WHERE g.id = p_graph_id
  ) THEN
    RAISE EXCEPTION 'Graph % does not exist', p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Basic validation for height (optional but sensible)
  IF p_height < 0 THEN
    RAISE EXCEPTION 'Conveyor height must be >= 0 (got %)', p_height
      USING ERRCODE = 'check_violation';
  END IF;

  -- Create parent node
  INSERT INTO public.wh_nodes (type, alias, tag_id, graph_id)
  VALUES ('conveyor', p_alias, p_tag_id, p_graph_id)
  RETURNING id INTO v_id;

  -- Create subtype row
  INSERT INTO public.wh_conveyor_nodes (id, x, y, height)
  VALUES (v_id, p_x, p_y, p_height);

  RETURN v_id;
END;
$$;

-- create a shelf (wh_nodes + wh_shelf_nodes) atomically
-- - Validates graph exists
-- - Optional alias (unique per graph enforced by wh_nodes constraint)
-- - Returns the created node id
-- - SECURITY DEFINER lets you grant EXECUTE while revoking table writes

CREATE OR REPLACE FUNCTION public.wh_create_shelf(
  p_graph_id bigint,
  p_x        real,
  p_y        real,
  p_alias    text DEFAULT NULL,
  p_tag_id   text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id bigint;
BEGIN
  -- Validate graph exists
  IF NOT EXISTS (
    SELECT 1 FROM public.wh_graphs g WHERE g.id = p_graph_id
  ) THEN
    RAISE EXCEPTION 'Graph % does not exist', p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Create parent node
  INSERT INTO public.wh_nodes (type, alias, tag_id, graph_id)
  VALUES ('shelf', p_alias, p_tag_id, p_graph_id)
  RETURNING id INTO v_id;

  -- Create subtype row
  INSERT INTO public.wh_shelf_nodes (id, x, y)
  VALUES (v_id, p_x, p_y);

  RETURN v_id;
END;
$$;

-- create a cell (wh_nodes + wh_cell_nodes + edge) atomically
-- - Validates graph exists
-- - Validates shelf_id exists and belongs to graph
-- - Validates level_id exists and belongs to graph
-- - Optional alias (unique per graph enforced by wh_nodes constraint)
-- - Auto-creates edge from shelf to cell (for routing)
-- - Returns the created node id
-- - SECURITY DEFINER lets you grant EXECUTE while revoking table writes

CREATE OR REPLACE FUNCTION public.wh_create_cell(
  p_graph_id     bigint,
  p_shelf_alias  text,
  p_level_alias  text,
  p_alias        text DEFAULT NULL,
  p_tag_id       text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_shelf_id bigint;
  v_level_id bigint;
BEGIN
  -- Find shelf id by alias in this graph
  SELECT n.id INTO v_shelf_id
  FROM public.wh_nodes n
  JOIN public.wh_shelf_nodes s ON s.id = n.id
  WHERE n.graph_id = p_graph_id
    AND n.alias = p_shelf_alias;

  IF v_shelf_id IS NULL THEN
    RAISE EXCEPTION 'Shelf alias "%" does not exist in graph %',
      p_shelf_alias, p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Find level id by alias in this graph (adjust columns if needed)
  SELECT l.id INTO v_level_id
  FROM public.wh_levels l
  WHERE l.graph_id = p_graph_id
    AND l.alias = p_level_alias;

  IF v_level_id IS NULL THEN
    RAISE EXCEPTION 'Level alias "%" does not exist in graph %',
      p_level_alias, p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Delegate to the original id-based function
  RETURN public.wh_create_cell(p_graph_id, v_shelf_id, v_level_id, p_alias, p_tag_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.wh_create_cell(
  p_graph_id bigint,
  p_shelf_id bigint,
  p_level_id bigint,
  p_alias    text DEFAULT NULL,
  p_tag_id   text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id bigint;
  v_shelf_graph_id bigint;
  v_level_graph_id bigint;
BEGIN
  -- Validate graph exists
  IF NOT EXISTS (
    SELECT 1 FROM public.wh_graphs g WHERE g.id = p_graph_id
  ) THEN
    RAISE EXCEPTION 'Graph % does not exist', p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Validate shelf exists and belongs to the graph
  SELECT n.graph_id INTO v_shelf_graph_id
  FROM public.wh_nodes n
  JOIN public.wh_shelf_nodes s ON s.id = n.id
  WHERE n.id = p_shelf_id;

  IF v_shelf_graph_id IS NULL THEN
    RAISE EXCEPTION 'Shelf % does not exist', p_shelf_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF v_shelf_graph_id <> p_graph_id THEN
    RAISE EXCEPTION 'Shelf % belongs to graph %, not graph %',
      p_shelf_id, v_shelf_graph_id, p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Validate level exists and belongs to the graph
  SELECT graph_id INTO v_level_graph_id
  FROM public.wh_levels
  WHERE id = p_level_id;

  IF v_level_graph_id IS NULL THEN
    RAISE EXCEPTION 'Level % does not exist', p_level_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF v_level_graph_id <> p_graph_id THEN
    RAISE EXCEPTION 'Level % belongs to graph %, not graph %',
      p_level_id, v_level_graph_id, p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Create parent node
  INSERT INTO public.wh_nodes (type, alias, tag_id, graph_id)
  VALUES ('cell', p_alias, p_tag_id, p_graph_id)
  RETURNING id INTO v_id;

  -- Create subtype row
  INSERT INTO public.wh_cell_nodes (id, shelf_id, level_id)
  VALUES (v_id, p_shelf_id, p_level_id);

  -- Auto-create edge from shelf to cell (for routing)
  -- Edge enables pathfinding, while shelf_id FK maintains structural relationship
  INSERT INTO public.wh_edges (graph_id, node_a_id, node_b_id)
  VALUES (
    p_graph_id,
    LEAST(p_shelf_id, v_id),
    GREATEST(p_shelf_id, v_id)
  );

  RETURN v_id;

EXCEPTION
  WHEN unique_violation THEN
    -- Most likely UNIQUE(graph_id, alias) in wh_nodes
    RAISE EXCEPTION 'Alias "%" already exists in graph %', p_alias, p_graph_id
      USING ERRCODE = 'unique_violation';
END;
$$;

-- create an edge (wh_edges) atomically
-- - Validates graph exists
-- - Validates both nodes exist and belong to the graph
-- - Prevents self-loops
-- - Prevents manual edges to/from cells (cells only connect via auto-created edge)
-- - Handles undirected edge uniqueness (A-B is same as B-A)
-- - Returns the created edge id
-- - SECURITY DEFINER lets you grant EXECUTE while revoking table writes

CREATE OR REPLACE FUNCTION public.wh_create_edge(
  p_graph_id  bigint,
  p_node_a_id bigint,
  p_node_b_id bigint
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id bigint;
  v_node_a_graph_id bigint;
  v_node_b_graph_id bigint;
  v_node_a_type node_type;
  v_node_b_type node_type;
BEGIN
  -- Validate graph exists
  IF NOT EXISTS (
    SELECT 1 FROM public.wh_graphs g WHERE g.id = p_graph_id
  ) THEN
    RAISE EXCEPTION 'Graph % does not exist', p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Validate no self-loop
  IF p_node_a_id = p_node_b_id THEN
    RAISE EXCEPTION 'Cannot create edge from node % to itself (self-loops not allowed)',
      p_node_a_id
      USING ERRCODE = 'check_violation';
  END IF;

  -- Validate node A exists and belongs to the graph
  SELECT graph_id, type INTO v_node_a_graph_id, v_node_a_type
  FROM public.wh_nodes
  WHERE id = p_node_a_id;

  IF v_node_a_graph_id IS NULL THEN
    RAISE EXCEPTION 'Node % does not exist', p_node_a_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF v_node_a_graph_id <> p_graph_id THEN
    RAISE EXCEPTION 'Node % belongs to graph %, not graph %',
      p_node_a_id, v_node_a_graph_id, p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Validate node B exists and belongs to the graph
  SELECT graph_id, type INTO v_node_b_graph_id, v_node_b_type
  FROM public.wh_nodes
  WHERE id = p_node_b_id;

  IF v_node_b_graph_id IS NULL THEN
    RAISE EXCEPTION 'Node % does not exist', p_node_b_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF v_node_b_graph_id <> p_graph_id THEN
    RAISE EXCEPTION 'Node % belongs to graph %, not graph %',
      p_node_b_id, v_node_b_graph_id, p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Prevent manual edges to/from cells (cells only connect to shelf via auto-created edge)
  IF v_node_a_type = 'cell' OR v_node_b_type = 'cell' THEN
    RAISE EXCEPTION 'Cannot manually create edges to/from cell nodes. Cells are automatically connected to their shelf.'
      USING ERRCODE = 'feature_not_supported',
            HINT = 'Cell edges are created automatically by wh_create_cell()';
  END IF;

  -- Create edge (normalize: always store with node_a < node_b for consistency)
  INSERT INTO public.wh_edges (graph_id, node_a_id, node_b_id)
  VALUES (
    p_graph_id,
    LEAST(p_node_a_id, p_node_b_id),
    GREATEST(p_node_a_id, p_node_b_id)
  )
  RETURNING id INTO v_id;

  RETURN v_id;

EXCEPTION
  WHEN unique_violation THEN
    -- Undirected edge already exists (either A-B or B-A)
    RAISE EXCEPTION 'Edge between nodes % and % already exists in graph %',
      LEAST(p_node_a_id, p_node_b_id),
      GREATEST(p_node_a_id, p_node_b_id),
      p_graph_id
      USING ERRCODE = 'unique_violation';
END;
$$;

CREATE OR REPLACE FUNCTION public.wh_create_edge(
  p_graph_id   bigint,
  p_node_a_alias text,
  p_node_b_alias text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_node_a_id bigint;
  v_node_b_id bigint;
BEGIN
  -- Resolve node A by alias
  SELECT n.id INTO v_node_a_id
  FROM public.wh_nodes n
  WHERE n.graph_id = p_graph_id
    AND n.alias = p_node_a_alias;

  IF v_node_a_id IS NULL THEN
    RAISE EXCEPTION 'Node alias "%" does not exist in graph %',
      p_node_a_alias, p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Resolve node B by alias
  SELECT n.id INTO v_node_b_id
  FROM public.wh_nodes n
  WHERE n.graph_id = p_graph_id
    AND n.alias = p_node_b_alias;

  IF v_node_b_id IS NULL THEN
    RAISE EXCEPTION 'Node alias "%" does not exist in graph %',
      p_node_b_alias, p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Delegate to the id-based function (keeps all validations, incl. no cells)
  RETURN public.wh_create_edge(p_graph_id, v_node_a_id, v_node_b_id);
END;
$$;

-- create a level (wh_levels) atomically
-- - Validates graph exists
-- - Validates height is non-negative
-- - Alias must be unique per graph (enforced by constraint)
-- - Returns the created level id
-- - SECURITY DEFINER lets you grant EXECUTE while revoking table writes

CREATE OR REPLACE FUNCTION public.wh_create_level(
  p_graph_id bigint,
  p_alias    text,
  p_height   real
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id bigint;
BEGIN
  -- Validate graph exists
  IF NOT EXISTS (
    SELECT 1 FROM public.wh_graphs g WHERE g.id = p_graph_id
  ) THEN
    RAISE EXCEPTION 'Graph % does not exist', p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Validate height is non-negative
  IF p_height < 0 THEN
    RAISE EXCEPTION 'Level height must be >= 0 (got %)', p_height
      USING ERRCODE = 'check_violation';
  END IF;

  -- Validate alias is not empty
  IF p_alias IS NULL OR trim(p_alias) = '' THEN
    RAISE EXCEPTION 'Level alias cannot be empty'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Create level
  INSERT INTO public.wh_levels (graph_id, alias, height)
  VALUES (p_graph_id, p_alias, p_height)
  RETURNING id INTO v_id;

  RETURN v_id;

EXCEPTION
  WHEN unique_violation THEN
    -- UNIQUE(graph_id, alias) violated
    RAISE EXCEPTION 'Level alias "%" already exists in graph %', p_alias, p_graph_id
      USING ERRCODE = 'unique_violation';
END;
$$;


-- Get depot
CREATE OR REPLACE FUNCTION public.wh_get_depot_node_id(p_graph_id bigint)
RETURNS bigint
LANGUAGE sql
STABLE
AS $$
  SELECT id
  FROM public.wh_nodes
  WHERE graph_id = p_graph_id
    AND type = 'depot';
$$;

-- --------------------
-- UTILITY Functions
-- --------------------

-- Update node position (x, y coordinates)
-- Works for depot, waypoint, conveyor, and shelf nodes
-- Cell nodes inherit position from shelf, so cannot be updated directly
CREATE OR REPLACE FUNCTION public.wh_update_node_position(
  p_node_id bigint,
  p_x       real,
  p_y       real
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_node_type node_type;
  v_rows_updated integer;
BEGIN
  -- Get node type
  SELECT type INTO v_node_type
  FROM public.wh_nodes
  WHERE id = p_node_id;

  IF v_node_type IS NULL THEN
    RAISE EXCEPTION 'Node % does not exist', p_node_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Update based on type
  IF v_node_type = 'depot' THEN
    UPDATE public.wh_depot_nodes
    SET x = p_x, y = p_y
    WHERE id = p_node_id;
    GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

  ELSIF v_node_type = 'waypoint' THEN
    UPDATE public.wh_waypoint_nodes
    SET x = p_x, y = p_y
    WHERE id = p_node_id;
    GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

  ELSIF v_node_type = 'conveyor' THEN
    UPDATE public.wh_conveyor_nodes
    SET x = p_x, y = p_y
    WHERE id = p_node_id;
    GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

  ELSIF v_node_type = 'shelf' THEN
    UPDATE public.wh_shelf_nodes
    SET x = p_x, y = p_y
    WHERE id = p_node_id;
    GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

  ELSIF v_node_type = 'cell' THEN
    RAISE EXCEPTION 'Cannot update position of cell node % (position inherited from shelf)', p_node_id
      USING ERRCODE = 'feature_not_supported';

  ELSE
    RAISE EXCEPTION 'Unknown node type: %', v_node_type;
  END IF;

  IF v_rows_updated = 0 THEN
    RAISE EXCEPTION 'Node % exists but has no coordinate data', p_node_id;
  END IF;
END;
$$;

-- Get node by alias
-- Returns the node id for a given alias in a graph
CREATE OR REPLACE FUNCTION public.wh_get_node_by_alias(
  p_graph_id bigint,
  p_alias    text
)
RETURNS TABLE (
  id bigint,
  alias text,
  tag_id text,
  type node_type,
  x real,
  y real,
  height real
)
LANGUAGE sql
STABLE
AS $$
  SELECT id, alias, tag_id, type, x, y, height
  FROM public.wh_nodes_view
  WHERE graph_id = p_graph_id
    AND alias = p_alias;
$$;

-- Get nodes by array of aliases in specified order
-- Returns id, alias, tag_id, type, x, y, height for each matching node
-- Validates all aliases belong to specified graph; preserves input array order
CREATE OR REPLACE FUNCTION public.wh_get_nodes_by_aliases(
  p_graph_id bigint,
  p_aliases  text[]
)
RETURNS TABLE(
  id bigint,
  alias text,
  tag_id text,
  type node_type,
  x real,
  y real,
  height real
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_invalid_aliases text[];
BEGIN
  -- Validate that all aliases exist in the specified graph
  SELECT array_agg(a)
  INTO v_invalid_aliases
  FROM unnest(p_aliases) AS a
  WHERE NOT EXISTS (
    SELECT 1 FROM public.wh_nodes_view
    WHERE wh_nodes_view.graph_id = p_graph_id AND wh_nodes_view.alias = a
  );

  IF v_invalid_aliases IS NOT NULL AND array_length(v_invalid_aliases, 1) > 0 THEN
    RAISE EXCEPTION 'Aliases % do not exist in graph %', v_invalid_aliases, p_graph_id;
  END IF;

  -- Return nodes in specified order
  RETURN QUERY
  SELECT
    nv.id,
    nv.alias,
    nv.tag_id,
    nv.type,
    nv.x,
    nv.y,
    nv.height
  FROM unnest(p_aliases) WITH ORDINALITY AS input(alias_val, ord)
  JOIN public.wh_nodes_view nv
    ON nv.alias = input.alias_val AND nv.graph_id = p_graph_id
  ORDER BY input.ord;
END;
$$;

-- Get node by tag_id
-- Returns the node id for a given tag_id in a graph
CREATE OR REPLACE FUNCTION public.wh_get_node_by_tag_id(
  p_graph_id bigint,
  p_tag_id   text
)
RETURNS TABLE (
  id bigint,
  alias text,
  tag_id text,
  type node_type,
  x real,
  y real,
  height real
)
LANGUAGE sql
STABLE
AS $$
  SELECT id, alias, tag_id, type, x, y, height
  FROM public.wh_nodes_view
  WHERE graph_id = p_graph_id
    AND tag_id = p_tag_id;
$$;

-- List nodes by graph and optional type filter
-- Returns table of nodes with their basic info
CREATE OR REPLACE FUNCTION public.wh_list_nodes_by_graph(
  p_graph_id bigint,
  p_node_type node_type DEFAULT NULL
)
RETURNS TABLE(
  id bigint,
  type node_type,
  alias text,
  created_at timestamptz
)
LANGUAGE sql
STABLE
AS $$
  SELECT id, type, alias, created_at
  FROM public.wh_nodes
  WHERE graph_id = p_graph_id
    AND (p_node_type IS NULL OR type = p_node_type)
  ORDER BY type, id;
$$;

-- Get nodes by array of IDs in specified order
-- Returns id, alias, type, x, y, height for each node
-- Preserves the order of input node_ids array
CREATE OR REPLACE FUNCTION public.wh_get_nodes_by_ids(
  p_node_ids bigint[]
)
RETURNS TABLE(
  id bigint,
  alias text,
  tag_id text,
  type node_type,
  x real,
  y real,
  height real
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    nv.id,
    nv.alias,
    nv.tag_id,
    nv.type,
    nv.x,
    nv.y,
    nv.height
  FROM unnest(p_node_ids) WITH ORDINALITY AS input(node_id, ord)
  JOIN public.wh_nodes_view nv ON nv.id = input.node_id
  ORDER BY input.ord;
$$;

-- Get nodes by array of IDs with graph validation
-- Validates all nodes belong to specified graph
-- Returns id, alias, tag_id, type, x, y, height for each node in specified order
CREATE OR REPLACE FUNCTION public.wh_get_nodes_by_ids(
  p_graph_id bigint,
  p_node_ids bigint[]
)
RETURNS TABLE(
  id bigint,
  alias text,
  tag_id text,
  type node_type,
  x real,
  y real,
  height real
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_invalid_nodes bigint[];
BEGIN
  -- Validate that all nodes belong to the specified graph
  SELECT array_agg(vid)
  INTO v_invalid_nodes
  FROM unnest(p_node_ids) AS vid
  WHERE NOT EXISTS (
    SELECT 1 FROM public.wh_nodes
    WHERE wh_nodes.graph_id = p_graph_id AND wh_nodes.id = vid
  );

  IF v_invalid_nodes IS NOT NULL AND array_length(v_invalid_nodes, 1) > 0 THEN
    RAISE EXCEPTION 'Nodes % do not exist in graph %', v_invalid_nodes, p_graph_id;
  END IF;

  -- Return nodes in specified order
  RETURN QUERY
  SELECT
    nv.id,
    nv.alias,
    nv.tag_id,
    nv.type,
    nv.x,
    nv.y,
    nv.height
  FROM unnest(p_node_ids) WITH ORDINALITY AS input(node_id, ord)
  JOIN public.wh_nodes_view nv ON nv.id = input.node_id
  WHERE nv.graph_id = p_graph_id
  ORDER BY input.ord;
END;
$$;

-- Delete node with validation
-- Prevents deletion of depot nodes (enforced by trigger anyway)
-- Cascade deletes edges and subtype records automatically
CREATE OR REPLACE FUNCTION public.wh_delete_node(p_node_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_node_type node_type;
BEGIN
  -- Get node type
  SELECT type INTO v_node_type
  FROM public.wh_nodes AS n
  WHERE n.id = p_node_id;

  IF v_node_type IS NULL THEN
    RAISE EXCEPTION 'Node % does not exist', p_node_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Depot deletion is prevented by trigger, but double-check here
  IF v_node_type = 'depot' THEN
    RAISE EXCEPTION 'Cannot delete depot node %', p_node_id
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  -- Delete node (CASCADE will handle subtype tables and edges)
  DELETE FROM public.wh_nodes WHERE id = p_node_id;
END;
$$;

-- Delete edge by edge id
CREATE OR REPLACE FUNCTION public.wh_delete_edge(p_edge_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows_deleted integer;
BEGIN
  DELETE FROM public.wh_edges WHERE id = p_edge_id;
  GET DIAGNOSTICS v_rows_deleted = ROW_COUNT;

  IF v_rows_deleted = 0 THEN
    RAISE EXCEPTION 'Edge % does not exist', p_edge_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;
END;
$$;

-- Delete edge by nodes (handles undirected edge lookup)
-- Accepts nodes in any order (A-B or B-A)
CREATE OR REPLACE FUNCTION public.wh_delete_edge_by_nodes(
  p_node_a_id bigint,
  p_node_b_id bigint
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows_deleted integer;
BEGIN
  -- Delete edge (normalized form: always node_a < node_b)
  DELETE FROM public.wh_edges
  WHERE node_a_id = LEAST(p_node_a_id, p_node_b_id)
    AND node_b_id = GREATEST(p_node_a_id, p_node_b_id);

  GET DIAGNOSTICS v_rows_deleted = ROW_COUNT;

  IF v_rows_deleted = 0 THEN
    RAISE EXCEPTION 'Edge between nodes % and % does not exist',
      LEAST(p_node_a_id, p_node_b_id),
      GREATEST(p_node_a_id, p_node_b_id)
      USING ERRCODE = 'foreign_key_violation';
  END IF;
END;
$$;

-- Get all edges connected to a node
-- Returns edges in both directions (undirected)
CREATE OR REPLACE FUNCTION public.wh_get_edges_by_node(p_node_id bigint)
RETURNS TABLE(
  edge_id bigint,
  node_a_id bigint,
  node_b_id bigint,
  other_node_id bigint,
  graph_id bigint
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    id AS edge_id,
    node_a_id,
    node_b_id,
    CASE
      WHEN node_a_id = p_node_id THEN node_b_id
      ELSE node_a_id
    END AS other_node_id,
    graph_id
  FROM public.wh_edges
  WHERE node_a_id = p_node_id OR node_b_id = p_node_id
  ORDER BY id;
$$;

--
-- --------------------
-- A* cost matrix where edge cost uses true 3D distance:
--   cost = sqrt( dx^2 + dy^2 + dz^2 )
-- Heuristic stays 2D (x,y) because pgRouting A* takes x1,y1,x2,y2.
-- --------------------
CREATE OR REPLACE FUNCTION public.wh_astar_cost_matrix(
  p_graph_id  bigint,
  p_vids      bigint[],
  p_directed  boolean DEFAULT false,
  p_heuristic integer DEFAULT 5,
  p_factor    double precision DEFAULT 1.0,
  p_epsilon   double precision DEFAULT 1.0
)
RETURNS TABLE(start_vid bigint, end_vid bigint, agg_cost double precision)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_invalid_nodes bigint[];
BEGIN
  -- Validate that all nodes belong to the specified graph
  SELECT array_agg(vid)
  INTO v_invalid_nodes
  FROM unnest(p_vids) AS vid
  WHERE NOT EXISTS (
    SELECT 1 FROM public.wh_nodes
    WHERE graph_id = p_graph_id AND id = vid
  );

  IF v_invalid_nodes IS NOT NULL AND array_length(v_invalid_nodes, 1) > 0 THEN
    RAISE EXCEPTION 'Nodes % do not exist in graph %', v_invalid_nodes, p_graph_id;
  END IF;

  -- Calculate cost matrix
  RETURN QUERY
  SELECT m.start_vid, m.end_vid, m.agg_cost
  FROM extensions.pgr_aStarCostMatrix(
    public.wh_build_pgrouting_edges_query_3d(p_graph_id),
    p_vids,
    directed  => p_directed,
    heuristic => p_heuristic,
    factor    => p_factor,
    epsilon   => p_epsilon
  ) AS m;
END;
$$;

CREATE OR REPLACE FUNCTION public.wh_astar_cost_matrix(
  p_graph_id   bigint,
  p_aliases    text[],
  p_directed   boolean DEFAULT false,
  p_heuristic  integer DEFAULT 5,
  p_factor     double precision DEFAULT 1.0,
  p_epsilon    double precision DEFAULT 1.0
)
RETURNS TABLE(start_vid bigint, end_vid bigint, agg_cost double precision)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_vids bigint[];
  v_missing text[];
BEGIN
  -- Find any missing aliases in the graph
  SELECT array_agg(a.alias)
  INTO v_missing
  FROM unnest(p_aliases) AS a(alias)
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.wh_nodes n
    WHERE n.graph_id = p_graph_id
      AND n.alias = a.alias
  );

  IF v_missing IS NOT NULL AND array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION 'Node aliases % do not exist in graph %', v_missing, p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Resolve aliases -> ids, preserving order of p_aliases
  SELECT array_agg(n.id ORDER BY a.ord)
  INTO v_vids
  FROM unnest(p_aliases) WITH ORDINALITY AS a(alias, ord)
  JOIN public.wh_nodes n
    ON n.graph_id = p_graph_id
   AND n.alias = a.alias;

  -- Delegate to the id-based function
  RETURN QUERY
  SELECT *
  FROM public.wh_astar_cost_matrix(
    p_graph_id,
    v_vids,
    p_directed,
    p_heuristic,
    p_factor,
    p_epsilon
  );
END;
$$;

-- Example:
-- SELECT * FROM public.wh_astar_cost_matrix(1, ARRAY[10,12,15,18]);

-- --------------------
-- Shortest Path Function
-- Returns the shortest path between two nodes as an array of node IDs
-- --------------------
CREATE OR REPLACE FUNCTION public.wh_astar_shortest_path(
  p_graph_id   bigint,
  p_start_vid  bigint,
  p_end_vid    bigint,
  p_directed   boolean DEFAULT false,
  p_heuristic  integer DEFAULT 5,
  p_factor     double precision DEFAULT 1.0,
  p_epsilon    double precision DEFAULT 1.0
)
RETURNS bigint[]
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_path bigint[];
BEGIN
  -- Validate that both nodes belong to the specified graph
  IF NOT EXISTS (
    SELECT 1 FROM public.wh_nodes
    WHERE graph_id = p_graph_id AND id = p_start_vid
  ) THEN
    RAISE EXCEPTION 'Start node % does not exist in graph %', p_start_vid, p_graph_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.wh_nodes
    WHERE graph_id = p_graph_id AND id = p_end_vid
  ) THEN
    RAISE EXCEPTION 'End node % does not exist in graph %', p_end_vid, p_graph_id;
  END IF;

  -- Get path as array
  SELECT array_agg(node ORDER BY path_seq)
  INTO v_path
  FROM extensions.pgr_astar(
    public.wh_build_pgrouting_edges_query_3d(p_graph_id),
    p_start_vid,
    p_end_vid,
    directed  => p_directed,
    heuristic => p_heuristic,
    factor    => p_factor,
    epsilon   => p_epsilon
  );

  -- If no path found, return empty array
  IF v_path IS NULL THEN
    RETURN ARRAY[]::bigint[];
  END IF;

  RETURN v_path;
END;
$$;

CREATE OR REPLACE FUNCTION public.wh_astar_shortest_path(
  p_graph_id    bigint,
  p_start_alias text,
  p_end_alias   text,
  p_directed    boolean DEFAULT false,
  p_heuristic   integer DEFAULT 5,
  p_factor      double precision DEFAULT 1.0,
  p_epsilon     double precision DEFAULT 1.0
)
RETURNS bigint[]
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_start_id bigint;
  v_end_id   bigint;
BEGIN
  -- Resolve start node by alias
  SELECT n.id INTO v_start_id
  FROM public.wh_nodes n
  WHERE n.graph_id = p_graph_id
    AND n.alias = p_start_alias;

  IF v_start_id IS NULL THEN
    RAISE EXCEPTION 'Start node alias "%" does not exist in graph %',
      p_start_alias, p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Resolve end node by alias
  SELECT n.id INTO v_end_id
  FROM public.wh_nodes n
  WHERE n.graph_id = p_graph_id
    AND n.alias = p_end_alias;

  IF v_end_id IS NULL THEN
    RAISE EXCEPTION 'End node alias "%" does not exist in graph %',
      p_end_alias, p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Delegate to the id-based function (keeps all validations + pgr params)
  RETURN public.wh_astar_shortest_path(
    p_graph_id,
    v_start_id,
    v_end_id,
    p_directed,
    p_heuristic,
    p_factor,
    p_epsilon
  );
END;
$$;


-- --------------------
-- Helper Function: Build pgRouting edges query with 3D distances
-- Returns the SQL query string used by pgRouting functions
-- --------------------
CREATE OR REPLACE FUNCTION public.wh_build_pgrouting_edges_query_3d(
  p_graph_id bigint
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN format($q$
    WITH node_xyz AS (
      -- depot: z = 0
      SELECT n.id AS node_id, d.x, d.y, 0::double precision AS z
      FROM public.wh_nodes n
      JOIN public.wh_depot_nodes d ON d.id = n.id
      WHERE n.graph_id = %1$s

      UNION ALL
      -- waypoint: z = 0
      SELECT n.id, w.x, w.y, 0::double precision AS z
      FROM public.wh_nodes n
      JOIN public.wh_waypoint_nodes w ON w.id = n.id
      WHERE n.graph_id = %1$s

      UNION ALL
      -- conveyor: z = conveyor.height
      SELECT n.id, c.x, c.y, c.height::double precision AS z
      FROM public.wh_nodes n
      JOIN public.wh_conveyor_nodes c ON c.id = n.id
      WHERE n.graph_id = %1$s

      UNION ALL
      -- shelf: z = 0 (shelf footprint on floor)
      SELECT n.id, s.x, s.y, 0::double precision AS z
      FROM public.wh_nodes n
      JOIN public.wh_shelf_nodes s ON s.id = n.id
      WHERE n.graph_id = %1$s

      UNION ALL
      -- cell: x,y from shelf; z from level.height
      SELECT n.id, s.x, s.y, lv.height::double precision AS z
      FROM public.wh_nodes n
      JOIN public.wh_cell_nodes cn ON cn.id = n.id
      JOIN public.wh_shelf_nodes s ON s.id = cn.shelf_id
      JOIN public.wh_levels lv ON lv.id = cn.level_id
      WHERE n.graph_id = %1$s
    )
    SELECT
      e.id,
      e.node_a_id AS source,
      e.node_b_id AS target,

      sqrt(
        (a.x - b.x)^2 +
        (a.y - b.y)^2 +
        (a.z - b.z)^2
      )::double precision AS cost,

      sqrt(
        (a.x - b.x)^2 +
        (a.y - b.y)^2 +
        (a.z - b.z)^2
      )::double precision AS reverse_cost,

      -- A* heuristic coordinates (2D)
      a.x::double precision AS x1,
      a.y::double precision AS y1,
      b.x::double precision AS x2,
      b.y::double precision AS y2
    FROM public.wh_edges e
    JOIN node_xyz a ON a.node_id = e.node_a_id
    JOIN node_xyz b ON b.node_id = e.node_b_id
    WHERE e.graph_id = %1$s
  $q$, p_graph_id);
END;
$$;


-- Example:
-- SELECT public.wh_astar_shortest_path(1, 10, 20);
-- Result: {10, 12, 15, 18, 20}

-- ============================================================================
-- CATEGORY 1: GRAPH MANAGEMENT FUNCTIONS
-- ============================================================================

-- Create a new warehouse graph
-- Auto-creates depot node at (0,0)
-- Returns the created graph id
CREATE OR REPLACE FUNCTION public.wh_create_graph(
  p_name     text,
  p_map_url  text DEFAULT NULL,
  p_map_res  real DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_graph_id bigint;
BEGIN
  -- Validate name is not empty
  IF p_name IS NULL OR trim(p_name) = '' THEN
    RAISE EXCEPTION 'Graph name cannot be empty'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Validate map resolution if provided
  IF p_map_res IS NOT NULL AND p_map_res <= 0 THEN
    RAISE EXCEPTION 'Map resolution must be positive (got %)', p_map_res
      USING ERRCODE = 'check_violation';
  END IF;

  -- Create graph (trigger will auto-create depot)
  INSERT INTO public.wh_graphs (name, map_url, map_res)
  VALUES (p_name, p_map_url, p_map_res)
  RETURNING id INTO v_graph_id;

  RETURN v_graph_id;

EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'Graph name "%" already exists', p_name
      USING ERRCODE = 'unique_violation';
END;
$$;

-- Delete entire graph with all contents
-- Leverages CASCADE from wh_graphs to delete all nodes, edges, levels
CREATE OR REPLACE FUNCTION public.wh_delete_graph(p_graph_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Validate graph exists
  IF NOT EXISTS (SELECT 1 FROM public.wh_graphs WHERE id = p_graph_id) THEN
    RAISE EXCEPTION 'Graph % does not exist', p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Delete graph (CASCADE handles nodes, edges, levels)
  DELETE FROM public.wh_graphs WHERE id = p_graph_id;
END;
$$;

-- List all graphs with statistics
CREATE OR REPLACE FUNCTION public.wh_list_graphs()
RETURNS TABLE(
  id bigint,
  name text,
  node_count bigint,
  edge_count bigint,
  level_count bigint,
  created_at timestamptz
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    g.id,
    g.name,
    COUNT(DISTINCT n.id) AS node_count,
    COUNT(DISTINCT e.id) AS edge_count,
    COUNT(DISTINCT l.id) AS level_count,
    g.created_at
  FROM public.wh_graphs g
  LEFT JOIN public.wh_nodes n ON n.graph_id = g.id
  LEFT JOIN public.wh_edges e ON e.graph_id = g.id
  LEFT JOIN public.wh_levels l ON l.graph_id = g.id
  GROUP BY g.id, g.name, g.created_at
  ORDER BY g.created_at DESC;
$$;

-- Get graph ID by name
CREATE OR REPLACE FUNCTION public.wh_get_graph_by_name(p_name text)
RETURNS bigint
LANGUAGE sql
STABLE
AS $$
  SELECT id
  FROM public.wh_graphs
  WHERE name = p_name;
$$;

-- Rename graph
CREATE OR REPLACE FUNCTION public.wh_rename_graph(
  p_graph_id bigint,
  p_new_name text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Validate graph exists
  IF NOT EXISTS (SELECT 1 FROM public.wh_graphs WHERE id = p_graph_id) THEN
    RAISE EXCEPTION 'Graph % does not exist', p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Validate new name is not empty
  IF p_new_name IS NULL OR trim(p_new_name) = '' THEN
    RAISE EXCEPTION 'Graph name cannot be empty'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Update name
  UPDATE public.wh_graphs
  SET name = p_new_name
  WHERE id = p_graph_id;

EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'Graph name "%" already exists', p_new_name
      USING ERRCODE = 'unique_violation';
END;
$$;

-- Clear all nodes and edges but keep graph structure
-- Preserves graph, levels, but removes all nodes (except depot) and edges
CREATE OR REPLACE FUNCTION public.wh_clear_graph(p_graph_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_depot_id bigint;
BEGIN
  -- Validate graph exists
  IF NOT EXISTS (SELECT 1 FROM public.wh_graphs WHERE id = p_graph_id) THEN
    RAISE EXCEPTION 'Graph % does not exist', p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Get depot ID (we'll preserve it)
  SELECT id INTO v_depot_id
  FROM public.wh_nodes
  WHERE graph_id = p_graph_id AND type = 'depot';

  -- Delete all edges
  DELETE FROM public.wh_edges WHERE graph_id = p_graph_id;

  -- Delete all non-depot nodes (CASCADE handles subtype tables)
  DELETE FROM public.wh_nodes
  WHERE graph_id = p_graph_id
    AND id <> v_depot_id;
END;
$$;

-- List all nodes with coordinates for a graph
-- Wrapper for wh_nodes_view
CREATE OR REPLACE FUNCTION public.wh_list_nodes_with_coordinates(p_graph_id bigint)
RETURNS TABLE(
  id bigint,
  type node_type,
  alias text,
  graph_id bigint,
  x real,
  y real,
  height real,
  shelf_id bigint,
  level_id bigint,
  created_at timestamptz
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    id,
    type,
    alias,
    graph_id,
    x,
    y,
    height,
    shelf_id,
    level_id,
    created_at
  FROM public.wh_nodes_view
  WHERE graph_id = p_graph_id
  ORDER BY type, id;
$$;

-- List all edges with details for a graph
-- Wrapper for wh_edges_view
CREATE OR REPLACE FUNCTION public.wh_list_edges_with_details(p_graph_id bigint)
RETURNS TABLE(
  edge_id bigint,
  graph_id bigint,
  node_a_id bigint,
  node_b_id bigint,
  node_a_type node_type,
  node_a_alias text,
  node_a_x real,
  node_a_y real,
  node_b_type node_type,
  node_b_alias text,
  node_b_x real,
  node_b_y real,
  created_at timestamptz,
  distance_2d real
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    edge_id,
    graph_id,
    node_a_id,
    node_b_id,
    node_a_type,
    node_a_alias,
    node_a_x,
    node_a_y,
    node_b_type,
    node_b_alias,
    node_b_x,
    node_b_y,
    created_at,
    distance_2d
  FROM public.wh_edges_view
  WHERE graph_id = p_graph_id
  ORDER BY edge_id;
$$;

-- Get warehouse statistics summary
-- Wrapper for wh_graph_summary_view
CREATE OR REPLACE FUNCTION public.wh_get_graph_summary(p_graph_id bigint)
RETURNS TABLE(
  graph_id bigint,
  graph_name text,
  map_url text,
  map_res real,
  depot_count bigint,
  waypoint_count bigint,
  conveyor_count bigint,
  shelf_count bigint,
  cell_count bigint,
  total_node_count bigint,
  edge_count bigint,
  level_count bigint,
  graph_created_at timestamptz,
  last_node_created_at timestamptz,
  last_edge_created_at timestamptz
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    graph_id,
    graph_name,
    map_url,
    map_res,
    depot_count,
    waypoint_count,
    conveyor_count,
    shelf_count,
    cell_count,
    total_node_count,
    edge_count,
    level_count,
    graph_created_at,
    last_node_created_at,
    last_edge_created_at
  FROM public.wh_graph_summary_view
  WHERE graph_id = p_graph_id;
$$;


-- ============================================================================
-- CATEGORY 2: LEVEL MANAGEMENT FUNCTIONS
-- ============================================================================

-- Delete level with validation
-- Prevents deletion if cells exist at this level
CREATE OR REPLACE FUNCTION public.wh_delete_level(p_level_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cell_count int;
BEGIN
  -- Validate level exists
  IF NOT EXISTS (SELECT 1 FROM public.wh_levels WHERE id = p_level_id) THEN
    RAISE EXCEPTION 'Level % does not exist', p_level_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Check if cells exist at this level
  SELECT COUNT(*) INTO v_cell_count
  FROM public.wh_cell_nodes
  WHERE level_id = p_level_id;

  IF v_cell_count > 0 THEN
    RAISE EXCEPTION 'Cannot delete level % because % cells exist at this level',
      p_level_id, v_cell_count
      USING ERRCODE = 'foreign_key_violation',
            HINT = 'Delete all cells at this level first';
  END IF;

  -- Delete level
  DELETE FROM public.wh_levels WHERE id = p_level_id;
END;
$$;

-- Update level height
CREATE OR REPLACE FUNCTION public.wh_update_level_height(
  p_level_id bigint,
  p_new_height real
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Validate level exists
  IF NOT EXISTS (SELECT 1 FROM public.wh_levels WHERE id = p_level_id) THEN
    RAISE EXCEPTION 'Level % does not exist', p_level_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Validate height is non-negative
  IF p_new_height < 0 THEN
    RAISE EXCEPTION 'Level height must be >= 0 (got %)', p_new_height
      USING ERRCODE = 'check_violation';
  END IF;

  -- Update height
  UPDATE public.wh_levels
  SET height = p_new_height
  WHERE id = p_level_id;
END;
$$;

-- List all levels in a graph with cell counts
CREATE OR REPLACE FUNCTION public.wh_list_levels(p_graph_id bigint)
RETURNS TABLE(
  id bigint,
  alias text,
  height real,
  cell_count bigint,
  created_at timestamptz
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    l.id,
    l.alias,
    l.height,
    COUNT(c.id) AS cell_count,
    l.created_at
  FROM public.wh_levels l
  LEFT JOIN public.wh_cell_nodes c ON c.level_id = l.id
  WHERE l.graph_id = p_graph_id
  GROUP BY l.id, l.alias, l.height, l.created_at
  ORDER BY l.height, l.alias;
$$;

-- Get level ID by alias
CREATE OR REPLACE FUNCTION public.wh_get_level_by_alias(
  p_graph_id bigint,
  p_alias text
)
RETURNS bigint
LANGUAGE sql
STABLE
AS $$
  SELECT id
  FROM public.wh_levels
  WHERE graph_id = p_graph_id
    AND alias = p_alias;
$$;


-- ============================================================================
-- CATEGORY 3: DEPOT MANAGEMENT FUNCTIONS
-- ============================================================================

-- Update depot position for a graph
CREATE OR REPLACE FUNCTION public.wh_update_depot_position(
  p_graph_id bigint,
  p_x real,
  p_y real
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_depot_id bigint;
BEGIN
  -- Validate graph exists
  IF NOT EXISTS (SELECT 1 FROM public.wh_graphs WHERE id = p_graph_id) THEN
    RAISE EXCEPTION 'Graph % does not exist', p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Get depot ID
  SELECT id INTO v_depot_id
  FROM public.wh_nodes
  WHERE graph_id = p_graph_id AND type = 'depot';

  IF v_depot_id IS NULL THEN
    RAISE EXCEPTION 'Depot not found for graph %', p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Update depot position
  UPDATE public.wh_depot_nodes
  SET x = p_x, y = p_y
  WHERE id = v_depot_id;
END;
$$;

-- Get depot position for a graph
CREATE OR REPLACE FUNCTION public.wh_get_depot_position(p_graph_id bigint)
RETURNS TABLE(x real, y real)
LANGUAGE sql
STABLE
AS $$
  SELECT d.x, d.y
  FROM public.wh_nodes n
  JOIN public.wh_depot_nodes d ON d.id = n.id
  WHERE n.graph_id = p_graph_id
    AND n.type = 'depot';
$$;

CREATE OR REPLACE FUNCTION public.wh_update_node_alias(
  p_node_id bigint,
  p_alias   text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows_updated integer;
BEGIN
  UPDATE public.wh_nodes
  SET alias = p_alias
  WHERE id = p_node_id;

  GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

  IF v_rows_updated = 0 THEN
    RAISE EXCEPTION 'Node % does not exist', p_node_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.wh_update_node_tag_id(
  p_node_id bigint,
  p_tag_id  text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows_updated integer;
BEGIN
  UPDATE public.wh_nodes
  SET tag_id = p_tag_id
  WHERE id = p_node_id;

  GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

  IF v_rows_updated = 0 THEN
    RAISE EXCEPTION 'Node % does not exist', p_node_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;
END;
$$;

-- Alias overload: update node position by alias
CREATE OR REPLACE FUNCTION public.wh_update_node_position(
  p_graph_id bigint,
  p_alias    text,
  p_x        real,
  p_y        real
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_node_id bigint;
BEGIN
  SELECT id INTO v_node_id
  FROM public.wh_nodes
  WHERE graph_id = p_graph_id
    AND alias = p_alias;

  IF v_node_id IS NULL THEN
    RAISE EXCEPTION 'Node alias "%" does not exist in graph %', p_alias, p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  PERFORM public.wh_update_node_position(v_node_id, p_x, p_y);
END;
$$;

-- Alias overload: delete node by alias
CREATE OR REPLACE FUNCTION public.wh_delete_node(
  p_graph_id bigint,
  p_alias    text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_node_id bigint;
BEGIN
  SELECT id INTO v_node_id
  FROM public.wh_nodes
  WHERE graph_id = p_graph_id
    AND alias = p_alias;

  IF v_node_id IS NULL THEN
    RAISE EXCEPTION 'Node alias "%" does not exist in graph %', p_alias, p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  PERFORM public.wh_delete_node(v_node_id);
END;
$$;

-- Alias overload: get edges by node alias
CREATE OR REPLACE FUNCTION public.wh_get_edges_by_node(
  p_graph_id bigint,
  p_alias    text
)
RETURNS TABLE(
  edge_id bigint,
  node_a_id bigint,
  node_b_id bigint,
  other_node_id bigint,
  graph_id bigint
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_node_id bigint;
BEGIN
  SELECT id INTO v_node_id
  FROM public.wh_nodes
  WHERE wh_nodes.graph_id = p_graph_id
    AND alias = p_alias;

  IF v_node_id IS NULL THEN
    RAISE EXCEPTION 'Node alias "%" does not exist in graph %', p_alias, p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  RETURN QUERY SELECT * FROM public.wh_get_edges_by_node(v_node_id);
END;
$$;

-- Alias overload: update node alias (find by current alias, set to new alias)
CREATE OR REPLACE FUNCTION public.wh_update_node_alias(
  p_graph_id      bigint,
  p_current_alias text,
  p_new_alias     text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_node_id bigint;
BEGIN
  SELECT id INTO v_node_id
  FROM public.wh_nodes
  WHERE graph_id = p_graph_id
    AND alias = p_current_alias;

  IF v_node_id IS NULL THEN
    RAISE EXCEPTION 'Node alias "%" does not exist in graph %', p_current_alias, p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  PERFORM public.wh_update_node_alias(v_node_id, p_new_alias);
END;
$$;

-- Alias overload: update node tag_id by alias
CREATE OR REPLACE FUNCTION public.wh_update_node_tag_id(
  p_graph_id bigint,
  p_alias    text,
  p_tag_id   text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_node_id bigint;
BEGIN
  SELECT id INTO v_node_id
  FROM public.wh_nodes
  WHERE graph_id = p_graph_id
    AND alias = p_alias;

  IF v_node_id IS NULL THEN
    RAISE EXCEPTION 'Node alias "%" does not exist in graph %', p_alias, p_graph_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  PERFORM public.wh_update_node_tag_id(v_node_id, p_tag_id);
END;
$$;

COMMIT;
