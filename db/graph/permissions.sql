BEGIN;

-- ============================================================================
-- PERMISSIONS & SECURITY MODEL
-- ============================================================================
--
-- This file defines the recommended permission model for warehouse graph API.
--
-- SECURITY APPROACH:
-- - Functions use SECURITY DEFINER (execute with schema owner privileges)
-- - Application roles get EXECUTE on functions only
-- - Direct table access is revoked from application roles
-- - Views are granted SELECT for read-only access
--
-- ROLES:
-- - app_user: Full API access (create, update, delete, query)
-- - app_readonly: Read-only access (views and query functions only)
--
-- ============================================================================

-- --------------------
-- Create Application Roles
-- --------------------

-- Full access role (can create, update, delete, query)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN
    CREATE ROLE app_user LOGIN;
    COMMENT ON ROLE app_user IS 'Application role with full API access';
  END IF;
END $$;

-- Read-only role (can only query)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_readonly') THEN
    CREATE ROLE app_readonly LOGIN;
    COMMENT ON ROLE app_readonly IS 'Application role with read-only access';
  END IF;
END $$;


-- --------------------
-- Grant EXECUTE on Creation Functions (app_user only)
-- --------------------

GRANT EXECUTE ON FUNCTION public.wh_create_graph(text, text, real) TO app_user;
GRANT EXECUTE ON FUNCTION public.wh_create_waypoint(bigint, real, real, text, text) TO app_user;
GRANT EXECUTE ON FUNCTION public.wh_create_conveyor(bigint, real, real, real, text, text) TO app_user;
GRANT EXECUTE ON FUNCTION public.wh_create_shelf(bigint, real, real, text, text) TO app_user;
GRANT EXECUTE ON FUNCTION public.wh_create_cell(bigint, bigint, bigint, text, text) TO app_user;
GRANT EXECUTE ON FUNCTION public.wh_create_edge(bigint, bigint, bigint) TO app_user;
GRANT EXECUTE ON FUNCTION public.wh_create_level(bigint, text, real) TO app_user;


-- --------------------
-- Grant EXECUTE on Query Functions (both roles)
-- --------------------

GRANT EXECUTE ON FUNCTION public.wh_list_graphs() TO app_user, app_readonly;
GRANT EXECUTE ON FUNCTION public.wh_list_nodes_with_coordinates(bigint) TO app_user, app_readonly;
GRANT EXECUTE ON FUNCTION public.wh_list_edges_with_details(bigint) TO app_user, app_readonly;
GRANT EXECUTE ON FUNCTION public.wh_get_graph_summary(bigint) TO app_user, app_readonly;
GRANT EXECUTE ON FUNCTION public.wh_get_depot_node_id(bigint) TO app_user, app_readonly;
GRANT EXECUTE ON FUNCTION public.wh_get_node_by_alias(bigint, text) TO app_user, app_readonly;
GRANT EXECUTE ON FUNCTION public.wh_list_nodes_by_graph(bigint, node_type) TO app_user, app_readonly;
GRANT EXECUTE ON FUNCTION public.wh_get_edges_by_node(bigint) TO app_user, app_readonly;


-- --------------------
-- Grant EXECUTE on Update Functions (app_user only)
-- --------------------

GRANT EXECUTE ON FUNCTION public.wh_update_node_position(bigint, real, real) TO app_user;


-- --------------------
-- Grant EXECUTE on Delete Functions (app_user only)
-- --------------------

GRANT EXECUTE ON FUNCTION public.wh_delete_node(bigint) TO app_user;
GRANT EXECUTE ON FUNCTION public.wh_delete_edge(bigint) TO app_user;
GRANT EXECUTE ON FUNCTION public.wh_delete_edge_by_nodes(bigint, bigint) TO app_user;


-- --------------------
-- Grant EXECUTE on Routing Functions (both roles)
-- --------------------

GRANT EXECUTE ON FUNCTION public.wh_astar_cost_matrix(bigint, bigint[], boolean, integer, double precision, double precision) TO app_user, app_readonly;
GRANT EXECUTE ON FUNCTION public.wh_astar_shortest_path(bigint, bigint, bigint, boolean, integer, double precision, double precision) TO app_user, app_readonly;
GRANT EXECUTE ON FUNCTION public.wh_build_pgrouting_edges_query_3d(bigint) TO app_user, app_readonly;


-- --------------------
-- Grant SELECT on Views (both roles)
-- --------------------

GRANT SELECT ON public.wh_nodes_view TO app_user, app_readonly;
GRANT SELECT ON public.wh_nodes_detailed_view TO app_user, app_readonly;
GRANT SELECT ON public.wh_edges_view TO app_user, app_readonly;
GRANT SELECT ON public.wh_graph_summary_view TO app_user, app_readonly;


-- --------------------
-- Grant SELECT on Base Tables (for metadata queries only)
-- --------------------

-- Allow reading graph metadata (but not modifying)
GRANT SELECT ON public.wh_graphs TO app_user, app_readonly;
GRANT SELECT ON public.wh_levels TO app_user, app_readonly;

-- Allow reading node types enum
GRANT USAGE ON TYPE public.node_type TO app_user, app_readonly;


-- --------------------
-- Revoke Direct Modification Access on Tables
-- --------------------

-- Ensure application roles cannot directly INSERT/UPDATE/DELETE on tables
-- (They must use SECURITY DEFINER functions instead)

REVOKE INSERT, UPDATE, DELETE ON public.wh_graphs FROM app_user, app_readonly;
REVOKE INSERT, UPDATE, DELETE ON public.wh_nodes FROM app_user, app_readonly;
REVOKE INSERT, UPDATE, DELETE ON public.wh_depot_nodes FROM app_user, app_readonly;
REVOKE INSERT, UPDATE, DELETE ON public.wh_waypoint_nodes FROM app_user, app_readonly;
REVOKE INSERT, UPDATE, DELETE ON public.wh_conveyor_nodes FROM app_user, app_readonly;
REVOKE INSERT, UPDATE, DELETE ON public.wh_shelf_nodes FROM app_user, app_readonly;
REVOKE INSERT, UPDATE, DELETE ON public.wh_cell_nodes FROM app_user, app_readonly;
REVOKE INSERT, UPDATE, DELETE ON public.wh_levels FROM app_user, app_readonly;
REVOKE INSERT, UPDATE, DELETE ON public.wh_edges FROM app_user, app_readonly;

-- Also revoke SELECT on internal tables (use views instead)
REVOKE SELECT ON public.wh_nodes FROM app_user, app_readonly;
REVOKE SELECT ON public.wh_depot_nodes FROM app_user, app_readonly;
REVOKE SELECT ON public.wh_waypoint_nodes FROM app_user, app_readonly;
REVOKE SELECT ON public.wh_conveyor_nodes FROM app_user, app_readonly;
REVOKE SELECT ON public.wh_shelf_nodes FROM app_user, app_readonly;
REVOKE SELECT ON public.wh_cell_nodes FROM app_user, app_readonly;
REVOKE SELECT ON public.wh_edges FROM app_user, app_readonly;


-- --------------------
-- Revoke Sequence Access (prevent ID manipulation)
-- --------------------
--
-- NOTE: Functions still work because they use SECURITY DEFINER!
-- - Functions execute with SCHEMA OWNER privileges
-- - Owner has sequence access, so INSERTs work
-- - Application roles cannot DIRECTLY access sequences
-- - This prevents: ID manipulation, sequence exhaustion, ID prediction
--
-- Example:
--   ❌ Direct: SELECT nextval('wh_nodes_id_seq')  -- Permission denied
--   ✅ Via API: SELECT wh_create_waypoint(...)    -- Works! (uses owner privilege)

REVOKE ALL ON SEQUENCE wh_graphs_id_seq FROM app_user, app_readonly;
REVOKE ALL ON SEQUENCE wh_nodes_id_seq FROM app_user, app_readonly;
REVOKE ALL ON SEQUENCE wh_levels_id_seq FROM app_user, app_readonly;
REVOKE ALL ON SEQUENCE wh_edges_id_seq FROM app_user, app_readonly;

GRANT SELECT ON public.wh_nodes_view TO anon, authenticated;
GRANT SELECT ON public.wh_nodes_detailed_view TO anon, authenticated;
-- --------------------
-- Summary Comments
-- --------------------

-- ROLE CAPABILITIES:
--
-- app_user (Full Access):
--   ✓ Create nodes, edges, levels (via functions)
--   ✓ Update node positions
--   ✓ Delete nodes and edges
--   ✓ Query all data (via views and functions)
--   ✓ Calculate routes
--   ✗ Direct table access (must use API)
--
-- app_readonly (Read-Only):
--   ✓ Query all data (via views and functions)
--   ✓ Calculate routes
--   ✗ Create, update, or delete (no EXECUTE on modification functions)
--   ✗ Direct table access
--
-- SECURITY BENEFITS:
-- 1. All validation logic enforced (can't bypass via direct INSERT)
-- 2. Cross-graph contamination prevented
-- 3. Depot protection enforced
-- 4. Cell edge rules enforced
-- 5. Audit trail possible (functions can log)
-- 6. Easy permission management (grant/revoke on functions)

COMMIT;
