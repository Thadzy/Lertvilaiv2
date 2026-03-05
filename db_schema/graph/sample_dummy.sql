-- 1) Create warehouse and set depot location
DO $$
DECLARE
  v_graph_id bigint;
BEGIN
  v_graph_id := wh_create_graph('test_wh');
  PERFORM set_config('wh.graph_id', v_graph_id::text, false);  -- false = session
END $$;

SELECT wh_update_depot_position(current_setting('wh.graph_id')::bigint, 3, 7);

-- 2) Create level
SELECT wh_create_level(current_setting('wh.graph_id')::bigint, 'L1', 0.5);
SELECT wh_create_level(current_setting('wh.graph_id')::bigint, 'L2', 1.25);
SELECT wh_create_level(current_setting('wh.graph_id')::bigint, 'L3', 2.0);

-- 3) Create conveyors
SELECT wh_create_conveyor(current_setting('wh.graph_id')::bigint, -3, 2, 1.0, 'I');
SELECT wh_create_conveyor(current_setting('wh.graph_id')::bigint, 8, 2, 1.2, 'O');

-- 4) Create waypoints
SELECT wh_create_waypoint(current_setting('wh.graph_id')::bigint, 1, 2, 'W1');
SELECT wh_create_waypoint(current_setting('wh.graph_id')::bigint, 1, 3, 'W2');
SELECT wh_create_waypoint(current_setting('wh.graph_id')::bigint, 1, 4, 'W3');
SELECT wh_create_waypoint(current_setting('wh.graph_id')::bigint, 1, 5, 'W4');
SELECT wh_create_waypoint(current_setting('wh.graph_id')::bigint, 1, 6, 'W5');

SELECT wh_create_waypoint(current_setting('wh.graph_id')::bigint, 3, 2, 'W6');
SELECT wh_create_waypoint(current_setting('wh.graph_id')::bigint, 3, 3, 'W7');
SELECT wh_create_waypoint(current_setting('wh.graph_id')::bigint, 3, 4, 'W8');
SELECT wh_create_waypoint(current_setting('wh.graph_id')::bigint, 3, 5, 'W9');
SELECT wh_create_waypoint(current_setting('wh.graph_id')::bigint, 3, 6, 'W10');

SELECT wh_create_waypoint(current_setting('wh.graph_id')::bigint, 5, 2, 'W11');
SELECT wh_create_waypoint(current_setting('wh.graph_id')::bigint, 5, 3, 'W12');
SELECT wh_create_waypoint(current_setting('wh.graph_id')::bigint, 5, 4, 'W13');
SELECT wh_create_waypoint(current_setting('wh.graph_id')::bigint, 5, 5, 'W14');
SELECT wh_create_waypoint(current_setting('wh.graph_id')::bigint, 5, 6, 'W15');

-- 5) Create shelves
SELECT wh_create_shelf(current_setting('wh.graph_id')::bigint, 2, 3, 'S1');
SELECT wh_create_shelf(current_setting('wh.graph_id')::bigint, 2, 4, 'S2');
SELECT wh_create_shelf(current_setting('wh.graph_id')::bigint, 2, 5, 'S3');
SELECT wh_create_shelf(current_setting('wh.graph_id')::bigint, 4, 3, 'S4');
SELECT wh_create_shelf(current_setting('wh.graph_id')::bigint, 4, 4, 'S5');
SELECT wh_create_shelf(current_setting('wh.graph_id')::bigint, 4, 5, 'S6');

-- 6) Create cells
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S1', 'L1', 'S1L1');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S1', 'L2', 'S1L2');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S1', 'L3', 'S1L3');

SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S2', 'L1', 'S2L1');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S2', 'L2', 'S2L2');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S2', 'L3', 'S2L3');

SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S3', 'L1', 'S3L1');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S3', 'L2', 'S3L2');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S3', 'L3', 'S3L3');

SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S4', 'L1', 'S4L1');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S4', 'L2', 'S4L2');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S4', 'L3', 'S4L3');

SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S5', 'L1', 'S5L1');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S5', 'L2', 'S5L2');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S5', 'L3', 'S5L3');

SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S6', 'L1', 'S6L1');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S6', 'L2', 'S6L2');
SELECT wh_create_cell(current_setting('wh.graph_id')::bigint, 'S6', 'L3', 'S6L3');

-- 7) Connect with edges
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W1', 'W2');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W2', 'W3');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W3', 'W4');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W4', 'W5');

SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W6', 'W7');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W7', 'W8');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W8', 'W9');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W9', 'W10');

SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W11', 'W12');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W12', 'W13');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W13', 'W14');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W14', 'W15');

SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W2', 'S1');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W3', 'S2');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W4', 'S3');

--- One shelf should be accessed from only one place for now
-- SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W7', 'S1');
-- SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W8', 'S2');
-- SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W9', 'S3');

-- SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W7', 'S4');
-- SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W8', 'S5');
-- SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W9', 'S6');

SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W12', 'S4');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W13', 'S5');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W14', 'S6');

SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'I', 'W1');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W1', 'W6');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W6', 'W11');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W11', 'O');

SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W5', 'W10');
SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W10', 'W15');

SELECT wh_create_edge(current_setting('wh.graph_id')::bigint, 'W10', '__depot__');


-- 8) Find shortest path
SELECT set_config('wh.graph_id', '10', false);
SELECT current_setting('wh.graph_id');

SELECT wh_astar_shortest_path(current_setting('wh.graph_id')::bigint, 'W3', 'W13');
SELECT wh_astar_shortest_path(current_setting('wh.graph_id')::bigint, 'I', 'O');
SELECT wh_astar_shortest_path(current_setting('wh.graph_id')::bigint, 'W8', 'W15');
SELECT wh_astar_shortest_path(current_setting('wh.graph_id')::bigint, 'O', 'W4');
SELECT wh_astar_shortest_path(current_setting('wh.graph_id')::bigint, 'W2', 'W14');

SELECT wh_astar_shortest_path(current_setting('wh.graph_id')::bigint, 'S3L3', 'S5L2');

WITH p AS (
  SELECT node_id, ord
  FROM unnest(wh_astar_shortest_path(current_setting('wh.graph_id')::bigint, 'W3', 'W13')) WITH ORDINALITY AS u(node_id, ord)
)
SELECT array_agg(n.alias ORDER BY p.ord) AS alias_path
FROM p
JOIN public.wh_nodes n
  ON n.id = p.node_id
 AND n.graph_id = current_setting('wh.graph_id')::bigint;

WITH p AS (
  SELECT node_id, ord
  FROM unnest(wh_astar_shortest_path(current_setting('wh.graph_id')::bigint, 'S3L3', 'S5L2')) WITH ORDINALITY AS u(node_id, ord)
)
SELECT array_agg(n.alias ORDER BY p.ord) AS alias_path
FROM p
JOIN public.wh_nodes n
  ON n.id = p.node_id
 AND n.graph_id = current_setting('wh.graph_id')::bigint;

-- Returns: {4, 5, 6}  (entrance → shelf → cell)