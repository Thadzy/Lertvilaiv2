# db/graph TODO List

## Priority 1 - Missing Functions ✅ COMPLETED

### Create Cell Function
- [x] Add `wh_create_cell(p_graph_id, p_alias, p_shelf_id, p_level_id)` to functions.sql
  - Validate graph exists
  - Validate shelf_id exists and belongs to graph
  - Validate level_id exists and belongs to graph
  - Handle unique constraint violations
  - Return created cell node id
  - Use SECURITY DEFINER pattern

### Create Edge Function
- [x] Add `wh_create_edge(p_graph_id, p_node_a_id, p_node_b_id)` to functions.sql
  - Validate both nodes exist in same graph
  - Validate no self-loops
  - Handle duplicate edge gracefully (better error than constraint violation)
  - **BONUS:** Normalize edges to always store node_a < node_b for consistency
  - Return created edge id
  - Use SECURITY DEFINER pattern

### Create Level Function
- [x] Add `wh_create_level(p_graph_id, p_alias, p_height)` to functions.sql
  - Validate graph exists
  - Validate height >= 0
  - Validate alias is not empty
  - Handle unique constraint violations (graph_id, alias)
  - Return created level id
  - Use SECURITY DEFINER pattern

---

## Priority 2 - Schema Constraints ✅ COMPLETED

### Add Missing Constraints
- [x] Add `CHECK (height >= 0)` to wh_levels table (tables.sql:69)
- [x] Review NULL alias behavior in wh_nodes
  - Documented: multiple NULL aliases per graph is intentional (optional aliases)
  - Added inline comments explaining UNIQUE behavior with NULL
- [x] Add cross-graph validation for cells
  - Added trigger function `wh_cell_nodes_validate_graph()`
  - Validates shelf and level belong to same graph as cell
  - Prevents cross-graph contamination even with direct INSERTs
- [x] **BONUS:** Add edge normalization constraint
  - Added `CHECK (node_a_id < node_b_id)` to enforce consistent storage

---

## Priority 3 - Additional Utility Functions ✅ COMPLETED

### Node Management
- [x] Add `wh_update_node_position(p_node_id, p_x, p_y)` for coordinate updates
  - Supports depot, waypoint, conveyor, shelf nodes
  - Prevents cell position updates (inherited from shelf)
  - Type-aware with proper validation
- [x] Add `wh_get_node_by_alias(p_graph_id, p_alias)` convenience lookup
- [x] Add `wh_list_nodes_by_graph(p_graph_id, p_node_type)` filtered listing
  - Optional type filter (returns all types if NULL)
  - Ordered by type and id
- [x] Add `wh_delete_node(p_node_id)` with additional validation
  - Prevents depot deletion (double-check on trigger)
  - Cascade deletes edges and subtype records

### Edge Management
- [x] Add `wh_delete_edge(p_edge_id)` - delete by edge id
- [x] Add `wh_delete_edge_by_nodes(p_node_a, p_node_b)` - delete by endpoints
  - Handles undirected edges (accepts nodes in any order)
  - Uses normalized form (LEAST/GREATEST)
- [x] Add `wh_get_edges_by_node(p_node_id)` to find all connected edges
  - Returns both endpoints + other_node_id for convenience
  - Works with undirected edges

---

## Priority 4 - Additional Views ✅ COMPLETED

### Useful Application Views
- [x] Create `wh_edges_view` - edges with node details joined
  - Includes node aliases, types, coordinates for both endpoints
  - Calculated 2D Euclidean distance
  - Easy to see edge connections with full context
- [x] Create `wh_graph_summary_view` - statistics per graph
  - Node counts by type (depot, waypoint, conveyor, shelf, cell)
  - Total node count, edge count, level count
  - Timestamps (graph created, last node/edge created)
  - One row per graph for dashboard/monitoring
- [ ] Consider materialized view for `wh_nodes_view` if performance becomes issue
  - Skipped: Regular views are sufficient for now
  - Can be added later if needed based on performance metrics

---

## Priority 5 - Documentation ✅ COMPLETED

### Schema Documentation
- [x] Add schema diagram (ERD) showing relationships
  - Text-based ERD in README.md
  - Can generate visual diagram using pgModeler, DBeaver, or dbdiagram.io
- [x] Document coordinate system expectations
  - Units: Recommended meters (can use other units consistently)
  - Origin: (0,0) typically at depot or warehouse corner
  - Z-axis: height for 3D routing (conveyors, cells)
  - 3D distance calculation with 2D heuristic
- [x] Add usage examples to functions.sql header
  - Complete graph creation example
  - Shortest path calculation
  - Cost matrix for TSP/VRP
  - Query examples with views
  - Update and delete operations

### API Documentation
- [x] Document expected workflow for graph creation
  - Step-by-step workflow in README.md
  - Create graph → levels → nodes → edges → route
- [x] Document pgRouting parameters (heuristic, factor, epsilon)
  - Detailed parameter explanations
  - Default values and recommendations
  - Performance vs. optimality tradeoffs
- [x] Add notes on SECURITY DEFINER usage and permissions
  - Recommended permission model
  - Security considerations
  - Function-level access control pattern

---

## Priority 6 - Testing & Validation ✅ COMPLETED

### Test Suite
- [x] Create `test.sql` with comprehensive tests (600+ lines)
  - 11 test suites covering all functionality
  - 40+ individual test cases
  - Tests for success cases and error conditions
  - Automatic pass/fail reporting
- [x] Test coverage includes:
  - Graph creation & depot auto-creation
  - Level creation with validation
  - All node types (waypoint, conveyor, shelf, cell)
  - Edge creation & normalization
  - Cell edge auto-creation & restrictions
  - Update operations
  - Query functions
  - Views (nodes, edges, graph summary)
  - Routing (shortest path, cost matrix)
  - Constraints & triggers (depot protection, cross-graph validation)
  - Delete operations
- [ ] Performance tests for large graphs (1000+ nodes)
  - Deferred: Can be added based on real-world performance metrics

---

## Priority 7 - Security Enhancements (Optional)

### Row-Level Security
- [ ] Evaluate need for RLS policies
  - Multi-tenant scenarios?
  - User-based access control?
- [ ] Consider audit logging for changes
  - Track who modified which graphs
  - History table for node/edge changes

### Permission Model
- [ ] Document recommended permission model
  - Which roles should have EXECUTE on functions
  - Direct table access restrictions
- [ ] Review all SECURITY DEFINER functions for SQL injection risks

---

## Priority 8 - Performance Optimization (Future)

### Indexing
- [ ] Monitor query patterns and add indexes as needed
- [ ] Consider GiST index on coordinates if doing spatial queries
- [ ] Evaluate if BRIN indexes useful for created_at columns

### Materialization
- [ ] Profile view query performance with real data volumes
- [ ] Consider materialized views if UNION ALL becomes slow
- [ ] Add refresh strategy if materialized views are used

---

## Completed ✓
- ✓ Split monolithic graph.sql into modular files
- ✓ Created merge.bash script for deployment
- ✓ Added denormalized wh_nodes_view
- ✓ Added wh_nodes_detailed_view with level info
- ✓ Organized functions by purpose (application vs routing)
- ✓ Moved trigger functions to triggers.sql
- ✓ **Priority 1 - Missing Functions (Complete)**
  - ✓ wh_create_cell - with cross-graph validation
  - ✓ wh_create_edge - with edge normalization (node_a < node_b)
  - ✓ wh_create_level - with height and alias validation
- ✓ **Priority 2 - Schema Constraints (Complete)**
  - ✓ CHECK constraint for non-negative level heights
  - ✓ Documented NULL alias behavior
  - ✓ Cross-graph validation trigger for cells
  - ✓ Edge normalization constraint (node_a < node_b)
- ✓ **Priority 3 - Additional Utility Functions (Complete)**
  - ✓ Node position updates (type-aware)
  - ✓ Node lookup by alias
  - ✓ Node listing with optional type filter
  - ✓ Safe node deletion with validation
  - ✓ Edge deletion (by id or by nodes)
  - ✓ Edge lookup by node
- ✓ **Priority 4 - Additional Views (Complete)**
  - ✓ wh_edges_view - edges with full node details
  - ✓ wh_graph_summary_view - per-graph statistics
- ✓ **Priority 5 - Documentation (Complete)**
  - ✓ README.md with comprehensive documentation
  - ✓ Coordinate system specifications
  - ✓ Complete usage examples
  - ✓ Workflow documentation
  - ✓ pgRouting parameter guide
  - ✓ Security and permissions model
- ✓ **Priority 6 - Testing & Validation (Complete)**
  - ✓ Comprehensive test suite (test.sql)
  - ✓ 11 test suites, 40+ test cases
  - ✓ Automated pass/fail reporting
  - ✓ Covers all functions, constraints, triggers, views

---

## Notes

### Current File Sizes
```
functions.sql:  8.8KB (48%)  - Routing logic
tables.sql:     3.2KB (17%)  - Schema definitions
triggers.sql:   2.0KB (11%)  - Business logic triggers
views.sql:      1.9KB (10%)  - Denormalized views
merge.bash:     1.4KB (8%)   - Build script
indexes.sql:    703B  (4%)   - Performance indexes
types.sql:      267B  (1%)   - Enum types
merged.sql:     18KB         - Full deployment file
```

### Design Patterns Used
- **Class Table Inheritance**: wh_nodes + type-specific tables
- **SECURITY DEFINER**: Controlled API for data modifications
- **Trigger-based Constraints**: Depot protection logic
- **Denormalized Views**: Easy querying without JOINs
- **pgRouting Integration**: 3D A* pathfinding
