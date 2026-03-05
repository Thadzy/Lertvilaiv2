-- ============================================================================
-- WAREHOUSE GRAPH SCHEMA TEST SUITE
-- ============================================================================
--
-- Comprehensive tests for all functions, constraints, triggers, and views
--
-- USAGE:
--   psql -d test_db -f merged.sql    # Deploy schema first
--   psql -d test_db -f test.sql      # Run tests
--
-- Expected output: All tests should PASS
-- Any FAIL indicates a problem
--
-- ============================================================================

BEGIN;

-- Setup: Clean slate
DO $$
BEGIN
  -- Drop test data if exists
  DELETE FROM wh_edges WHERE graph_id IN (SELECT id FROM wh_graphs WHERE name LIKE 'test_%');
  DELETE FROM wh_nodes WHERE graph_id IN (SELECT id FROM wh_graphs WHERE name LIKE 'test_%');
  DELETE FROM wh_levels WHERE graph_id IN (SELECT id FROM wh_graphs WHERE name LIKE 'test_%');
  DELETE FROM wh_graphs WHERE name LIKE 'test_%';
END $$;

-- Test tracking
CREATE TEMP TABLE test_results (
  test_id serial,
  test_name text,
  status text,
  message text
);

-- Helper function to record test results
CREATE OR REPLACE FUNCTION record_test(p_name text, p_status text, p_message text DEFAULT NULL)
RETURNS void AS $$
BEGIN
  INSERT INTO test_results (test_name, status, message)
  VALUES (p_name, p_status, p_message);
  RAISE NOTICE '% - %: %', p_status, p_name, COALESCE(p_message, '');
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- TEST SUITE 1: Graph Creation & Depot Auto-Creation
-- ============================================================================

DO $$
DECLARE
  v_graph_id bigint;
  v_depot_id bigint;
BEGIN
  -- Test 1.1: Create graph
  v_graph_id := wh_create_graph('test_graph_1', 'test.png', 0.1);

  IF v_graph_id IS NOT NULL THEN
    PERFORM record_test('1.1 Create graph', 'PASS', 'Graph ID: ' || v_graph_id);
  ELSE
    PERFORM record_test('1.1 Create graph', 'FAIL', 'No graph ID returned');
  END IF;

  -- Test 1.2: Depot auto-created
  SELECT id INTO v_depot_id
  FROM wh_nodes
  WHERE graph_id = v_graph_id AND type = 'depot';

  IF v_depot_id IS NOT NULL THEN
    PERFORM record_test('1.2 Depot auto-created', 'PASS', 'Depot ID: ' || v_depot_id);
  ELSE
    PERFORM record_test('1.2 Depot auto-created', 'FAIL', 'No depot found');
  END IF;

  -- Test 1.3: Depot has correct alias
  IF EXISTS (SELECT 1 FROM wh_nodes WHERE id = v_depot_id AND alias = '__depot__') THEN
    PERFORM record_test('1.3 Depot alias correct', 'PASS');
  ELSE
    PERFORM record_test('1.3 Depot alias correct', 'FAIL', 'Depot alias not __depot__');
  END IF;

  -- Test 1.4: Depot has coordinates (auto-initialized to 0,0)
  IF EXISTS (SELECT 1 FROM wh_depot_nodes WHERE id = v_depot_id AND x = 0 AND y = 0) THEN
    PERFORM record_test('1.4 Depot coordinates initialized', 'PASS');
  ELSE
    PERFORM record_test('1.4 Depot coordinates initialized', 'FAIL');
  END IF;
END $$;


-- ============================================================================
-- TEST SUITE 2: Level Creation
-- ============================================================================

DO $$
DECLARE
  v_graph_id bigint;
  v_level_ground bigint;
  v_level_1 bigint;
BEGIN
  SELECT id INTO v_graph_id FROM wh_graphs WHERE name = 'test_graph_1';

  -- Test 2.1: Create ground level
  v_level_ground := wh_create_level(v_graph_id, 'ground', 0.0);
  IF v_level_ground IS NOT NULL THEN
    PERFORM record_test('2.1 Create ground level', 'PASS', 'Level ID: ' || v_level_ground);
  ELSE
    PERFORM record_test('2.1 Create ground level', 'FAIL');
  END IF;

  -- Test 2.2: Create elevated level
  v_level_1 := wh_create_level(v_graph_id, 'level_1', 3.0);
  IF v_level_1 IS NOT NULL THEN
    PERFORM record_test('2.2 Create elevated level', 'PASS', 'Level ID: ' || v_level_1);
  ELSE
    PERFORM record_test('2.2 Create elevated level', 'FAIL');
  END IF;

  -- Test 2.3: Duplicate level alias should fail
  BEGIN
    PERFORM wh_create_level(v_graph_id, 'ground', 1.0);
    PERFORM record_test('2.3 Duplicate level alias rejected', 'FAIL', 'Should have raised exception');
  EXCEPTION WHEN unique_violation THEN
    PERFORM record_test('2.3 Duplicate level alias rejected', 'PASS');
  END;

  -- Test 2.4: Negative height should fail
  BEGIN
    PERFORM wh_create_level(v_graph_id, 'basement', -1.0);
    PERFORM record_test('2.4 Negative height rejected', 'FAIL', 'Should have raised exception');
  EXCEPTION WHEN check_violation THEN
    PERFORM record_test('2.4 Negative height rejected', 'PASS');
  END;
END $$;


-- ============================================================================
-- TEST SUITE 3: Node Creation (Waypoint, Conveyor, Shelf)
-- ============================================================================

DO $$
DECLARE
  v_graph_id bigint;
  v_waypoint_id bigint;
  v_conveyor_id bigint;
  v_shelf_id bigint;
BEGIN
  SELECT id INTO v_graph_id FROM wh_graphs WHERE name = 'test_graph_1';

  -- Test 3.1: Create waypoint
  v_waypoint_id := wh_create_waypoint(v_graph_id, 5.0, 5.0, 'entrance');
  IF v_waypoint_id IS NOT NULL THEN
    PERFORM record_test('3.1 Create waypoint', 'PASS', 'Waypoint ID: ' || v_waypoint_id);
  ELSE
    PERFORM record_test('3.1 Create waypoint', 'FAIL');
  END IF;

  -- Test 3.2: Create conveyor with height
  v_conveyor_id := wh_create_conveyor(v_graph_id, 10.0, 5.0, 2.5, 'conv_1');
  IF v_conveyor_id IS NOT NULL THEN
    PERFORM record_test('3.2 Create conveyor', 'PASS', 'Conveyor ID: ' || v_conveyor_id);
  ELSE
    PERFORM record_test('3.2 Create conveyor', 'FAIL');
  END IF;

  -- Test 3.3: Create shelf
  v_shelf_id := wh_create_shelf(v_graph_id, 15.0, 5.0, 'shelf_A');
  IF v_shelf_id IS NOT NULL THEN
    PERFORM record_test('3.3 Create shelf', 'PASS', 'Shelf ID: ' || v_shelf_id);
  ELSE
    PERFORM record_test('3.3 Create shelf', 'FAIL');
  END IF;

  -- Test 3.4: Waypoint has coordinates
  IF EXISTS (SELECT 1 FROM wh_waypoint_nodes WHERE id = v_waypoint_id AND x = 5.0 AND y = 5.0) THEN
    PERFORM record_test('3.4 Waypoint coordinates correct', 'PASS');
  ELSE
    PERFORM record_test('3.4 Waypoint coordinates correct', 'FAIL');
  END IF;

  -- Test 3.5: Conveyor has height
  IF EXISTS (SELECT 1 FROM wh_conveyor_nodes WHERE id = v_conveyor_id AND height = 2.5) THEN
    PERFORM record_test('3.5 Conveyor height correct', 'PASS');
  ELSE
    PERFORM record_test('3.5 Conveyor height correct', 'FAIL');
  END IF;
END $$;


-- ============================================================================
-- TEST SUITE 4: Cell Creation & Auto-Edge
-- ============================================================================

DO $$
DECLARE
  v_graph_id bigint;
  v_shelf_id bigint;
  v_level_id bigint;
  v_cell_id bigint;
  v_edge_count int;
BEGIN
  SELECT id INTO v_graph_id FROM wh_graphs WHERE name = 'test_graph_1';
  SELECT id INTO v_shelf_id FROM wh_nodes WHERE graph_id = v_graph_id AND alias = 'shelf_A';
  SELECT id INTO v_level_id FROM wh_levels WHERE graph_id = v_graph_id AND alias = 'ground';

  -- Test 4.1: Create cell
  v_cell_id := wh_create_cell(v_graph_id, v_shelf_id, v_level_id, 'cell_A1');
  IF v_cell_id IS NOT NULL THEN
    PERFORM record_test('4.1 Create cell', 'PASS', 'Cell ID: ' || v_cell_id);
  ELSE
    PERFORM record_test('4.1 Create cell', 'FAIL');
  END IF;

  -- Test 4.2: Edge auto-created from shelf to cell
  SELECT COUNT(*) INTO v_edge_count
  FROM wh_edges
  WHERE graph_id = v_graph_id
    AND ((node_a_id = v_shelf_id AND node_b_id = v_cell_id)
      OR (node_a_id = v_cell_id AND node_b_id = v_shelf_id));

  IF v_edge_count = 1 THEN
    PERFORM record_test('4.2 Cell edge auto-created', 'PASS');
  ELSE
    PERFORM record_test('4.2 Cell edge auto-created', 'FAIL', 'Edge count: ' || v_edge_count);
  END IF;

  -- Test 4.3: Cell has correct shelf_id
  IF EXISTS (SELECT 1 FROM wh_cell_nodes WHERE id = v_cell_id AND shelf_id = v_shelf_id) THEN
    PERFORM record_test('4.3 Cell shelf_id correct', 'PASS');
  ELSE
    PERFORM record_test('4.3 Cell shelf_id correct', 'FAIL');
  END IF;

  -- Test 4.4: Cell inherits coordinates from shelf
  IF EXISTS (
    SELECT 1 FROM wh_nodes_view
    WHERE id = v_cell_id AND x = 15.0 AND y = 5.0
  ) THEN
    PERFORM record_test('4.4 Cell coordinates inherited', 'PASS');
  ELSE
    PERFORM record_test('4.4 Cell coordinates inherited', 'FAIL');
  END IF;
END $$;


-- ============================================================================
-- TEST SUITE 5: Edge Creation & Validation
-- ============================================================================

DO $$
DECLARE
  v_graph_id bigint;
  v_waypoint_id bigint;
  v_shelf_id bigint;
  v_cell_id bigint;
  v_edge_id bigint;
BEGIN
  SELECT id INTO v_graph_id FROM wh_graphs WHERE name = 'test_graph_1';
  SELECT id INTO v_waypoint_id FROM wh_nodes WHERE graph_id = v_graph_id AND alias = 'entrance';
  SELECT id INTO v_shelf_id FROM wh_nodes WHERE graph_id = v_graph_id AND alias = 'shelf_A';
  SELECT id INTO v_cell_id FROM wh_nodes WHERE graph_id = v_graph_id AND alias = 'cell_A1';

  -- Test 5.1: Create edge between waypoint and shelf
  v_edge_id := wh_create_edge(v_graph_id, v_waypoint_id, v_shelf_id);
  IF v_edge_id IS NOT NULL THEN
    PERFORM record_test('5.1 Create edge', 'PASS', 'Edge ID: ' || v_edge_id);
  ELSE
    PERFORM record_test('5.1 Create edge', 'FAIL');
  END IF;

  -- Test 5.2: Edge is normalized (node_a < node_b)
  IF EXISTS (
    SELECT 1 FROM wh_edges
    WHERE id = v_edge_id AND node_a_id < node_b_id
  ) THEN
    PERFORM record_test('5.2 Edge normalized', 'PASS');
  ELSE
    PERFORM record_test('5.2 Edge normalized', 'FAIL');
  END IF;

  -- Test 5.3: Duplicate edge rejected (undirected)
  BEGIN
    PERFORM wh_create_edge(v_graph_id, v_shelf_id, v_waypoint_id);  -- Reversed order
    PERFORM record_test('5.3 Duplicate edge rejected', 'FAIL', 'Should have raised exception');
  EXCEPTION WHEN unique_violation THEN
    PERFORM record_test('5.3 Duplicate edge rejected', 'PASS');
  END;

  -- Test 5.4: Self-loop rejected
  BEGIN
    PERFORM wh_create_edge(v_graph_id, v_waypoint_id, v_waypoint_id);
    PERFORM record_test('5.4 Self-loop rejected', 'FAIL', 'Should have raised exception');
  EXCEPTION WHEN check_violation THEN
    PERFORM record_test('5.4 Self-loop rejected', 'PASS');
  END;

  -- Test 5.5: Manual edge to cell rejected
  BEGIN
    PERFORM wh_create_edge(v_graph_id, v_waypoint_id, v_cell_id);
    PERFORM record_test('5.5 Manual cell edge rejected', 'FAIL', 'Should have raised exception');
  EXCEPTION WHEN feature_not_supported THEN
    PERFORM record_test('5.5 Manual cell edge rejected', 'PASS');
  END;
END $$;


-- ============================================================================
-- TEST SUITE 6: Update Operations
-- ============================================================================

DO $$
DECLARE
  v_waypoint_id bigint;
  v_new_x real;
  v_new_y real;
BEGIN
  SELECT id INTO v_waypoint_id
  FROM wh_nodes
  WHERE alias = 'entrance' AND graph_id = (SELECT id FROM wh_graphs WHERE name = 'test_graph_1');

  -- Test 6.1: Update waypoint position
  PERFORM wh_update_node_position(v_waypoint_id, 6.0, 6.0);

  SELECT x, y INTO v_new_x, v_new_y
  FROM wh_waypoint_nodes
  WHERE id = v_waypoint_id;

  IF v_new_x = 6.0 AND v_new_y = 6.0 THEN
    PERFORM record_test('6.1 Update node position', 'PASS');
  ELSE
    PERFORM record_test('6.1 Update node position', 'FAIL', format('Got (%.1f, %.1f)', v_new_x, v_new_y));
  END IF;

  -- Test 6.2: Update cell position should fail
  BEGIN
    PERFORM wh_update_node_position(
      (SELECT id FROM wh_nodes WHERE alias = 'cell_A1'),
      10.0, 10.0
    );
    PERFORM record_test('6.2 Cell position update rejected', 'FAIL', 'Should have raised exception');
  EXCEPTION WHEN feature_not_supported THEN
    PERFORM record_test('6.2 Cell position update rejected', 'PASS');
  END;
END $$;


-- ============================================================================
-- TEST SUITE 7: Query Functions
-- ============================================================================

DO $$
DECLARE
  v_graph_id bigint;
  v_depot_id bigint;
  v_waypoint_id bigint;
  v_node_count int;
BEGIN
  SELECT id INTO v_graph_id FROM wh_graphs WHERE name = 'test_graph_1';

  -- Test 7.1: Get depot by graph
  v_depot_id := wh_get_depot_node_id(v_graph_id);
  IF v_depot_id IS NOT NULL THEN
    PERFORM record_test('7.1 Get depot by graph', 'PASS', 'Depot ID: ' || v_depot_id);
  ELSE
    PERFORM record_test('7.1 Get depot by graph', 'FAIL');
  END IF;

  -- Test 7.2: Get node by alias
  v_waypoint_id := wh_get_node_by_alias(v_graph_id, 'entrance');
  IF v_waypoint_id IS NOT NULL THEN
    PERFORM record_test('7.2 Get node by alias', 'PASS', 'Node ID: ' || v_waypoint_id);
  ELSE
    PERFORM record_test('7.2 Get node by alias', 'FAIL');
  END IF;

  -- Test 7.3: List nodes by type
  SELECT COUNT(*) INTO v_node_count
  FROM wh_list_nodes_by_graph(v_graph_id, 'waypoint');

  IF v_node_count > 0 THEN
    PERFORM record_test('7.3 List nodes by type', 'PASS', 'Waypoint count: ' || v_node_count);
  ELSE
    PERFORM record_test('7.3 List nodes by type', 'FAIL');
  END IF;

  -- Test 7.4: Get edges by node
  IF EXISTS (
    SELECT 1 FROM wh_get_edges_by_node(v_waypoint_id)
  ) THEN
    PERFORM record_test('7.4 Get edges by node', 'PASS');
  ELSE
    PERFORM record_test('7.4 Get edges by node', 'FAIL', 'No edges found');
  END IF;
END $$;


-- ============================================================================
-- TEST SUITE 8: Views
-- ============================================================================

DO $$
DECLARE
  v_graph_id bigint;
  v_node_count int;
  v_edge_count int;
BEGIN
  SELECT id INTO v_graph_id FROM wh_graphs WHERE name = 'test_graph_1';

  -- Test 8.1: wh_nodes_view has all nodes
  SELECT COUNT(*) INTO v_node_count
  FROM wh_nodes_view
  WHERE graph_id = v_graph_id;

  IF v_node_count >= 5 THEN  -- depot + waypoint + conveyor + shelf + cell
    PERFORM record_test('8.1 Nodes view populated', 'PASS', 'Node count: ' || v_node_count);
  ELSE
    PERFORM record_test('8.1 Nodes view populated', 'FAIL', 'Node count: ' || v_node_count);
  END IF;

  -- Test 8.2: wh_edges_view has edge details
  SELECT COUNT(*) INTO v_edge_count
  FROM wh_edges_view
  WHERE graph_id = v_graph_id;

  IF v_edge_count >= 2 THEN  -- waypoint-shelf + shelf-cell
    PERFORM record_test('8.2 Edges view populated', 'PASS', 'Edge count: ' || v_edge_count);
  ELSE
    PERFORM record_test('8.2 Edges view populated', 'FAIL', 'Edge count: ' || v_edge_count);
  END IF;

  -- Test 8.3: wh_graph_summary_view has statistics
  IF EXISTS (
    SELECT 1 FROM wh_graph_summary_view
    WHERE graph_id = v_graph_id
      AND total_node_count > 0
      AND edge_count > 0
  ) THEN
    PERFORM record_test('8.3 Graph summary view correct', 'PASS');
  ELSE
    PERFORM record_test('8.3 Graph summary view correct', 'FAIL');
  END IF;
END $$;


-- ============================================================================
-- TEST SUITE 9: Routing (pgRouting)
-- ============================================================================

DO $$
DECLARE
  v_graph_id bigint;
  v_start_id bigint;
  v_end_id bigint;
  v_path bigint[];
  v_cost_matrix_count int;
BEGIN
  SELECT id INTO v_graph_id FROM wh_graphs WHERE name = 'test_graph_1';
  SELECT id INTO v_start_id FROM wh_nodes WHERE graph_id = v_graph_id AND alias = 'entrance';
  SELECT id INTO v_end_id FROM wh_nodes WHERE graph_id = v_graph_id AND alias = 'cell_A1';

  -- Test 9.1: Calculate shortest path
  v_path := wh_astar_shortest_path(v_graph_id, v_start_id, v_end_id);

  IF array_length(v_path, 1) >= 2 THEN
    PERFORM record_test('9.1 Shortest path calculated', 'PASS', 'Path length: ' || array_length(v_path, 1));
  ELSE
    PERFORM record_test('9.1 Shortest path calculated', 'FAIL', 'Path: ' || v_path::text);
  END IF;

  -- Test 9.2: Path starts with start node
  IF v_path[1] = v_start_id THEN
    PERFORM record_test('9.2 Path starts correctly', 'PASS');
  ELSE
    PERFORM record_test('9.2 Path starts correctly', 'FAIL');
  END IF;

  -- Test 9.3: Path ends with end node
  IF v_path[array_length(v_path, 1)] = v_end_id THEN
    PERFORM record_test('9.3 Path ends correctly', 'PASS');
  ELSE
    PERFORM record_test('9.3 Path ends correctly', 'FAIL');
  END IF;

  -- Test 9.4: Cost matrix
  SELECT COUNT(*) INTO v_cost_matrix_count
  FROM wh_astar_cost_matrix(
    v_graph_id,
    ARRAY[v_start_id, v_end_id]
  );

  IF v_cost_matrix_count >= 2 THEN  -- At least start->end and end->start
    PERFORM record_test('9.4 Cost matrix calculated', 'PASS', 'Pairs: ' || v_cost_matrix_count);
  ELSE
    PERFORM record_test('9.4 Cost matrix calculated', 'FAIL');
  END IF;
END $$;


-- ============================================================================
-- TEST SUITE 10: Constraints & Triggers
-- ============================================================================

DO $$
DECLARE
  v_graph_id bigint;
  v_depot_id bigint;
BEGIN
  SELECT id INTO v_graph_id FROM wh_graphs WHERE name = 'test_graph_1';
  SELECT id INTO v_depot_id FROM wh_nodes WHERE graph_id = v_graph_id AND type = 'depot';

  -- Test 10.1: Depot deletion blocked
  BEGIN
    DELETE FROM wh_nodes WHERE id = v_depot_id;
    PERFORM record_test('10.1 Depot deletion blocked', 'FAIL', 'Should have raised exception');
  EXCEPTION WHEN OTHERS THEN
    PERFORM record_test('10.1 Depot deletion blocked', 'PASS');
  END;

  -- Test 10.2: Depot type change blocked
  BEGIN
    UPDATE wh_nodes SET type = 'waypoint' WHERE id = v_depot_id;
    PERFORM record_test('10.2 Depot type change blocked', 'FAIL', 'Should have raised exception');
  EXCEPTION WHEN OTHERS THEN
    PERFORM record_test('10.2 Depot type change blocked', 'PASS');
  END;

  -- Test 10.3: Cross-graph cell validation
  DECLARE
    v_graph_2_id bigint;
    v_shelf_g1 bigint;
    v_level_g2 bigint;
  BEGIN
    -- Create second graph
    v_graph_2_id := wh_create_graph('test_graph_2');

    -- Create level in graph 2
    v_level_g2 := wh_create_level(v_graph_2_id, 'ground', 0.0);

    -- Get shelf from graph 1
    SELECT id INTO v_shelf_g1 FROM wh_nodes WHERE graph_id = v_graph_id AND alias = 'shelf_A';

    -- Try to create cell with shelf from graph 1 and level from graph 2 (should fail)
    BEGIN
      PERFORM wh_create_cell(v_graph_id, v_shelf_g1, v_level_g2, 'bad_cell');
      PERFORM record_test('10.3 Cross-graph cell rejected', 'FAIL', 'Should have raised exception');
    EXCEPTION WHEN OTHERS THEN
      PERFORM record_test('10.3 Cross-graph cell rejected', 'PASS');
    END;
  END;
END $$;


-- ============================================================================
-- TEST SUITE 11: Delete Operations
-- ============================================================================

DO $$
DECLARE
  v_graph_id bigint;
  v_waypoint_id bigint;
  v_edge_id bigint;
BEGIN
  SELECT id INTO v_graph_id FROM wh_graphs WHERE name = 'test_graph_1';

  -- Create test waypoint for deletion
  v_waypoint_id := wh_create_waypoint(v_graph_id, 20.0, 20.0, 'temp_waypoint');

  -- Test 11.1: Delete node
  PERFORM wh_delete_node(v_waypoint_id);

  IF NOT EXISTS (SELECT 1 FROM wh_nodes WHERE id = v_waypoint_id) THEN
    PERFORM record_test('11.1 Delete node', 'PASS');
  ELSE
    PERFORM record_test('11.1 Delete node', 'FAIL', 'Node still exists');
  END IF;

  -- Test 11.2: Delete edge by nodes
  DECLARE
    v_shelf_id bigint;
    v_cell_id bigint;
  BEGIN
    SELECT id INTO v_shelf_id FROM wh_nodes WHERE graph_id = v_graph_id AND alias = 'shelf_A';
    SELECT id INTO v_cell_id FROM wh_nodes WHERE graph_id = v_graph_id AND alias = 'cell_A1';

    -- Delete the auto-created edge
    PERFORM wh_delete_edge_by_nodes(v_shelf_id, v_cell_id);

    IF NOT EXISTS (
      SELECT 1 FROM wh_edges
      WHERE (node_a_id = v_shelf_id AND node_b_id = v_cell_id)
         OR (node_a_id = v_cell_id AND node_b_id = v_shelf_id)
    ) THEN
      PERFORM record_test('11.2 Delete edge by nodes', 'PASS');
    ELSE
      PERFORM record_test('11.2 Delete edge by nodes', 'FAIL', 'Edge still exists');
    END IF;
  END;
END $$;


-- ============================================================================
-- TEST RESULTS SUMMARY
-- ============================================================================

DO $$
DECLARE
  v_total int;
  v_passed int;
  v_failed int;
  rec RECORD;
BEGIN
  SELECT COUNT(*),
         COUNT(*) FILTER (WHERE status = 'PASS'),
         COUNT(*) FILTER (WHERE status = 'FAIL')
  INTO v_total, v_passed, v_failed
  FROM test_results;

  RAISE NOTICE '';
  RAISE NOTICE '========================================';
  RAISE NOTICE 'TEST SUMMARY';
  RAISE NOTICE '========================================';
  RAISE NOTICE 'Total:  %', v_total;
  RAISE NOTICE 'Passed: %', v_passed;
  RAISE NOTICE 'Failed: %', v_failed;
  RAISE NOTICE '========================================';

  IF v_failed > 0 THEN
    RAISE NOTICE '';
    RAISE NOTICE 'FAILED TESTS:';
    FOR rec IN (SELECT test_name, message FROM test_results WHERE status = 'FAIL') LOOP
      RAISE NOTICE '  - %: %', rec.test_name, COALESCE(rec.message, '');
    END LOOP;
  END IF;

  RAISE NOTICE '';
END $$;

-- Show all test results
SELECT test_id, test_name, status, message
FROM test_results
ORDER BY test_id;

ROLLBACK;  -- Don't save test data

-- ============================================================================
-- END OF TEST SUITE
-- ============================================================================
