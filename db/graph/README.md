# Warehouse Graph API - Quick Reference

PostgreSQL schema for warehouse routing and pathfinding using pgRouting.

## Quick Start

```sql
-- 1. Deploy schema
\i merged.sql

-- 2. Create a warehouse graph
SELECT wh_create_graph('my_warehouse');
-- Returns: 1 (depot auto-created at 0,0)

-- 3. Create storage structure
SELECT wh_create_level(1, 'ground', 0.0);       -- Level for shelf heights
SELECT wh_create_waypoint(1, 5.0, 5.0, 'entry');  -- Navigation point
SELECT wh_create_shelf(1, 10.0, 5.0, 'shelf_A');  -- Storage shelf

-- 4. Create storage cells
SELECT wh_create_cell(1, 'shelf_A', 'ground', 'cell_A1');  -- Auto-creates shelf→cell edge

-- 5. Connect with routing edges
SELECT wh_create_edge(1, 'entry', 'shelf_A');

-- 6. Find shortest path
SELECT wh_astar_shortest_path(1, 'entry', 'cell_A1');
-- Returns: array of node IDs forming the path
```

---

## Function Reference

### 📋 What Function Do I Use To...?

#### **Create Things**
- **Create a warehouse graph** → `wh_create_graph('name', 'map.png', 0.1)`
- **Create a navigation point** → `wh_create_waypoint(graph_id, x, y, alias)`
- **Create a shelf** → `wh_create_shelf(graph_id, x, y, alias)`
- **Create a storage cell** → `wh_create_cell(graph_id, shelf_alias, level_alias, alias)`
- **Create a conveyor** → `wh_create_conveyor(graph_id, x, y, height, alias)`
- **Create height levels** → `wh_create_level(graph_id, alias, height)`
- **Connect two nodes** → `wh_create_edge(graph_id, node_alias_a, node_alias_b)`

#### **Find Things**
- **List all warehouses** → `SELECT * FROM wh_list_graphs()`
- **Get warehouse by name** → `wh_get_graph_by_name('warehouse_name')`
- **Find node by name** → `wh_get_node_by_alias(graph_id, 'node_alias')`
- **List all nodes** → `wh_list_nodes_by_graph(graph_id)`
- **List nodes of specific type** → `wh_list_nodes_by_graph(graph_id, 'waypoint')`
- **Get depot location** → `wh_get_depot_position(graph_id)`
- **List levels** → `wh_list_levels(graph_id)`
- **Get edges for a node** → `wh_get_edges_by_node(node_id)`

#### **Update Things**
- **Move a node** → `wh_update_node_position(node_id, new_x, new_y)`
- **Move the depot** → `wh_update_depot_position(graph_id, x, y)`
- **Rename warehouse** → `wh_rename_graph(graph_id, 'new_name')`
- **Change level height** → `wh_update_level_height(level_id, new_height)`
- **Rename a node** → `wh_update_node_alias(node_id, 'new_alias')`
- **Change node tag** → `wh_update_node_tag_id(node_id, 'new_tag_id')`

#### **Delete Things**
- **Delete entire warehouse** → `wh_delete_graph(graph_id)` ⚠️ Deletes everything
- **Clear warehouse (keep structure)** → `wh_clear_graph(graph_id)` (keeps levels, removes nodes/edges)
- **Delete a node** → `wh_delete_node(node_id)`
- **Delete an edge** → `wh_delete_edge_by_nodes(node_a_id, node_b_id)`
- **Delete a level** → `wh_delete_level(level_id)` (fails if cells exist)

#### **Calculate Routes**
- **Find shortest path** → `wh_astar_shortest_path(graph_id, start_alias, end_alias)`
- **Get all distances between points** → `wh_astar_cost_matrix(graph_id, ARRAY['alias1', 'alias2', ...])`

#### **View Data**
- **See all nodes with coordinates** → `wh_list_nodes_with_coordinates(graph_id)`
- **See all edges with details** → `wh_list_edges_with_details(graph_id)`
- **Get warehouse statistics** → `wh_get_graph_summary(graph_id)`

---

## Complete Function List

### 🏗️ Graph Management

```sql
-- Create warehouse
wh_create_graph(name, [map_url], [map_res])
  → Returns: graph_id
  → Example: SELECT wh_create_graph('warehouse_1', 'map.png', 0.1);

-- List all warehouses
wh_list_graphs()
  → Returns: id, name, node_count, edge_count, level_count, created_at

-- Find warehouse by name
wh_get_graph_by_name(name text)
  → Returns: graph_id

-- Rename warehouse
wh_rename_graph(graph_id, new_name)

-- Delete entire warehouse (cascades everything)
wh_delete_graph(graph_id)

-- Clear warehouse contents (keeps graph, levels, depot)
wh_clear_graph(graph_id)
```

### 🏭 Node Creation

```sql
-- Create waypoint (navigation point)
wh_create_waypoint(graph_id, x, y, alias)
  → Returns: node_id

-- Create conveyor (with height)
wh_create_conveyor(graph_id, x, y, height, alias)
  → Returns: node_id

-- Create shelf
wh_create_shelf(graph_id, x, y, alias)
  → Returns: node_id

-- Create storage cell (auto-creates edge to shelf)
wh_create_cell(graph_id, shelf_alias, level_alias, cell_alias)
  → Returns: node_id
  ⚠️ Automatically creates shelf→cell edge

-- OVERLOAD: Create cell by IDs
wh_create_cell(graph_id, shelf_id, level_id, cell_alias)
  → Returns: node_id
```

### 📏 Level Management

```sql
-- Create height level
wh_create_level(graph_id, alias, height)
  → Returns: level_id

-- List all levels in warehouse
wh_list_levels(graph_id)
  → Returns: id, alias, height, cell_count, created_at

-- Find level by name
wh_get_level_by_alias(graph_id, alias)
  → Returns: level_id

-- Update level height
wh_update_level_height(level_id, new_height)

-- Delete level (fails if cells exist)
wh_delete_level(level_id)
```

### 🔗 Edge Management

```sql
-- Create edge between two nodes (by IDs)
wh_create_edge(graph_id, node_a_id, node_b_id)
  → Returns: edge_id
  ⚠️ Cannot manually connect cells (auto-created only)

-- OVERLOAD: Create edge by aliases
wh_create_edge(graph_id, node_a_alias, node_b_alias)
  → Returns: edge_id

-- Delete edge by node IDs (works in either direction)
wh_delete_edge_by_nodes(node_a_id, node_b_id)

-- Delete edge by edge ID
wh_delete_edge(edge_id)

-- Get all edges connected to a node
wh_get_edges_by_node(node_id)
  → Returns: edge_id, node_a_id, node_b_id, other_node_id, graph_id
```

### 🔍 Node Queries

```sql
-- Find node by alias
wh_get_node_by_alias(graph_id, alias)
  → Returns: node_id

-- List all nodes (or filter by type)
wh_list_nodes_by_graph(graph_id, [node_type])
  → Returns: id, type, alias, created_at
  → Types: 'waypoint', 'conveyor', 'shelf', 'cell', 'depot'

-- Get depot ID
wh_get_depot_node_id(graph_id)
  → Returns: node_id

-- Get depot position
wh_get_depot_position(graph_id)
  → Returns: x, y
```

### ✏️ Node Updates

```sql
-- Move node (works for waypoint, conveyor, shelf, depot)
wh_update_node_position(node_id, new_x, new_y)
  ⚠️ Cannot move cells (x,y inherited from shelf, height from level)

-- Move depot
wh_update_depot_position(graph_id, x, y)

-- Rename a node (alias must be unique per graph)
wh_update_node_alias(node_id, new_alias)

-- Change node tag ID
wh_update_node_tag_id(node_id, new_tag_id)
```

### 🗑️ Node Deletion

```sql
-- Delete node (cascades to edges)
wh_delete_node(node_id)
  ⚠️ Cannot delete depot
  ⚠️ Deletes all connected edges
```

### 🗺️ Routing & Pathfinding

```sql
-- Find shortest path (by node IDs)
wh_astar_shortest_path(graph_id, start_id, end_id, [directed], [heuristic], [factor], [epsilon])
  → Returns: bigint[] (array of node IDs)

-- OVERLOAD: Find shortest path by aliases
wh_astar_shortest_path(graph_id, start_alias, end_alias, ...)
  → Returns: bigint[]

-- Calculate distance matrix (by node IDs)
wh_astar_cost_matrix(graph_id, node_ids_array[], [directed], [heuristic], [factor], [epsilon])
  → Returns: TABLE(start_vid, end_vid, agg_cost)
  → Use for TSP/VRP optimization

-- OVERLOAD: Distance matrix by aliases
wh_astar_cost_matrix(graph_id, aliases_array[], ...)
  → Returns: TABLE(start_vid, end_vid, agg_cost)
```

**Routing Parameters (all optional):**
- `directed` (default: false) - Set true for one-way edges
- `heuristic` (default: 5) - A* heuristic (5 = Manhattan distance)
- `factor` (default: 1.0) - Cost multiplier
- `epsilon` (default: 1.0) - Speed vs optimality (1.0 = optimal)

---

## Views & Query Functions

```sql
-- All nodes with coordinates (recommended: use function)
SELECT * FROM wh_list_nodes_with_coordinates(1);
-- Or directly query view:
-- SELECT * FROM wh_nodes_view WHERE graph_id = 1;
  → Columns: id, type, alias, tag_id, graph_id, x, y, height, shelf_id, level_id, created_at

-- All edges with endpoint details (recommended: use function)
SELECT * FROM wh_list_edges_with_details(1);
-- Or directly query view:
-- SELECT * FROM wh_edges_view WHERE graph_id = 1;
  → Columns: edge_id, graph_id, node_a/b (id, type, alias, x, y), distance_2d, created_at

-- Warehouse statistics (recommended: use function)
SELECT * FROM wh_get_graph_summary(1);
-- Or directly query view:
-- SELECT * FROM wh_graph_summary_view WHERE graph_id = 1;
  → Columns: graph details, node counts by type, edge_count, level_count

-- Nodes with level details (view only - for advanced queries)
SELECT * FROM wh_nodes_detailed_view
WHERE graph_id = 1;
  → Adds: level_alias, level_height (useful for filtering by level attributes)
```

---

## Common Workflows

### Setup a New Warehouse

```sql
-- 1. Create graph
SELECT wh_create_graph('warehouse_main');
-- Returns: 1 (with depot auto-created at 0,0)

-- 2. Define height levels
SELECT wh_create_level(1, 'ground', 0.0);
SELECT wh_create_level(1, 'level_1', 3.0);
SELECT wh_create_level(1, 'level_2', 6.0);

-- 3. Position the depot
SELECT wh_update_depot_position(1, 0.0, 0.0);

-- 4. Create navigation grid
SELECT wh_create_waypoint(1, 5.0, 0.0, 'entry');
SELECT wh_create_waypoint(1, 5.0, 5.0, 'aisle_1');
SELECT wh_create_waypoint(1, 10.0, 5.0, 'aisle_2');

-- 5. Create shelves
SELECT wh_create_shelf(1, 3.0, 5.0, 'shelf_A');
SELECT wh_create_shelf(1, 7.0, 5.0, 'shelf_B');

-- 6. Add storage cells (edges auto-created)
SELECT wh_create_cell(1, 'shelf_A', 'ground', 'A1');
SELECT wh_create_cell(1, 'shelf_A', 'level_1', 'A2');
SELECT wh_create_cell(1, 'shelf_B', 'ground', 'B1');

-- 7. Connect everything
SELECT wh_create_edge(1, '__depot__', 'entry');
SELECT wh_create_edge(1, 'entry', 'aisle_1');
SELECT wh_create_edge(1, 'aisle_1', 'shelf_A');
SELECT wh_create_edge(1, 'aisle_1', 'aisle_2');
SELECT wh_create_edge(1, 'aisle_2', 'shelf_B');
-- Note: shelf→cell edges already exist (auto-created in step 6)

-- 8. Verify setup
SELECT * FROM wh_get_graph_summary(1);
```

### Calculate Optimal Routes

```sql
-- Single path from entry to cell
SELECT wh_astar_shortest_path(1, 'entry', 'A1');
-- Returns: {4, 5, 7} (node IDs along path)

-- Get distances between multiple locations
SELECT * FROM wh_astar_cost_matrix(
  1,
  ARRAY['entry', 'A1', 'A2', 'B1']
);
-- Returns table of pairwise costs for TSP/VRP
```

### Maintenance Operations

```sql
-- Move a waypoint
SELECT wh_update_node_position(
  (SELECT id FROM wh_nodes_view WHERE alias = 'aisle_1'),
  5.5, 5.5
);

-- Remove a node and its edges
SELECT wh_delete_node(
  (SELECT id FROM wh_nodes_view WHERE alias = 'old_waypoint')
);

-- Clear warehouse and start over
SELECT wh_clear_graph(1);
-- Keeps graph, levels, depot; removes all nodes/edges

-- Completely delete warehouse
SELECT wh_delete_graph(1);
-- Deletes everything
```

---

## Important Rules

### ⚠️ Cell Edge Restrictions

**Cells are special:**
- ✅ Cell→shelf edges are **automatically created** when you create a cell
- ❌ You **cannot manually create** edges to/from cells
- ✅ You **can delete** cell edges if needed (e.g., to make cell inaccessible)

```sql
-- ✅ CORRECT: Auto-creates edge
SELECT wh_create_cell(1, 'shelf_A', 'ground', 'cell_A1');

-- ❌ ERROR: Cannot manually connect cells
SELECT wh_create_edge(1, 'waypoint_1', 'cell_A1');
-- ERROR: Cannot manually create edges to/from cell nodes

-- ✅ ALLOWED: Delete cell edge
SELECT wh_delete_edge_by_nodes(shelf_id, cell_id);
```

### 🔒 Depot Protection

- **Depot auto-created** when you create a graph
- **Cannot delete depot** directly (protected by trigger)
- **Can delete graph** (depot deleted via CASCADE)
- **Depot always named** `__depot__`

### 📐 Coordinates

- **Units:** Use consistent units (meters recommended)
- **Origin:** Typically (0, 0) = depot or warehouse corner
- **3D System:**
  - Ground-level nodes: z = 0
  - Conveyors: z = conveyor.height
  - Cells: z = level.height

---

## Schema Tables

```
wh_graphs              -- Warehouse definitions
wh_nodes               -- All nodes (polymorphic base)
  ├── wh_depot_nodes      -- Depot (one per graph)
  ├── wh_waypoint_nodes   -- Navigation points
  ├── wh_conveyor_nodes   -- Elevated conveyors
  ├── wh_shelf_nodes      -- Storage shelves
  └── wh_cell_nodes       -- Storage cells
wh_edges               -- Routing connections
wh_levels              -- Height levels
```

---

## Dependencies

- **PostgreSQL** 12+
- **pgRouting** 3.0+ (for pathfinding)

---

## Files

```
db/graph/
├── README.md         # This file
├── merged.sql        # Deploy this file (generated)
├── merge.bash        # Regenerates merged.sql
│
├── types.sql         # Enum definitions
├── tables.sql        # Schema
├── indexes.sql       # Performance
├── functions.sql     # API functions
├── triggers.sql      # Business logic
├── views.sql         # Convenience views
└── permissions.sql   # Security roles
```

**To deploy:** `psql -d your_database -f merged.sql`

---

## Security Model

Functions use `SECURITY DEFINER` pattern:
- Application needs only `EXECUTE` permission on functions
- Direct table access revoked from app
- All validation enforced in functions
- Two roles: `app_user` (full), `app_readonly` (read-only)

---

## Examples

See `sample.sql` for a complete working example.

For more details, see inline documentation in `functions.sql`.

---

## Appendix: Complete Function Reference Table

### Graph Management Functions

| Function | Parameters | Returns | Description |
|----------|------------|---------|-------------|
| `wh_create_graph(name, [map_url], [map_res])` | name: text<br>map_url: text (optional)<br>map_res: real (optional) | bigint | Create new warehouse graph (auto-creates depot) |
| `wh_list_graphs()` | - | TABLE | List all warehouses with statistics |
| `wh_get_graph_by_name(name)` | name: text | bigint | Find graph ID by name |
| `wh_rename_graph(graph_id, new_name)` | graph_id: bigint<br>new_name: text | void | Rename warehouse |
| `wh_delete_graph(graph_id)` | graph_id: bigint | void | Delete entire warehouse (CASCADE all) |
| `wh_clear_graph(graph_id)` | graph_id: bigint | void | Clear nodes/edges, keep graph/levels/depot |
| `wh_list_nodes_with_coordinates(graph_id)` | graph_id: bigint | TABLE | List all nodes with coordinates for a warehouse |
| `wh_list_edges_with_details(graph_id)` | graph_id: bigint | TABLE | List all edges with endpoint details for a warehouse |
| `wh_get_graph_summary(graph_id)` | graph_id: bigint | TABLE | Get warehouse statistics summary |

### Node Creation Functions

| Function | Parameters | Returns | Description |
|----------|------------|---------|-------------|
| `wh_create_waypoint(graph_id, x, y, alias)` | graph_id: bigint<br>x: real<br>y: real<br>alias: text | bigint | Create navigation waypoint |
| `wh_create_conveyor(graph_id, x, y, height, alias)` | graph_id: bigint<br>x: real<br>y: real<br>height: real<br>alias: text | bigint | Create conveyor with height |
| `wh_create_shelf(graph_id, x, y, alias)` | graph_id: bigint<br>x: real<br>y: real<br>alias: text | bigint | Create storage shelf |
| `wh_create_cell(graph_id, shelf_alias, level_alias, alias)` | graph_id: bigint<br>shelf_alias: text<br>level_alias: text<br>alias: text | bigint | Create cell by aliases (auto-creates edge) |
| `wh_create_cell(graph_id, shelf_id, level_id, alias)` | graph_id: bigint<br>shelf_id: bigint<br>level_id: bigint<br>alias: text | bigint | Create cell by IDs (auto-creates edge) |

### Level Management Functions

| Function | Parameters | Returns | Description |
|----------|------------|---------|-------------|
| `wh_create_level(graph_id, alias, height)` | graph_id: bigint<br>alias: text<br>height: real | bigint | Create height level |
| `wh_list_levels(graph_id)` | graph_id: bigint | TABLE | List levels with cell counts |
| `wh_get_level_by_alias(graph_id, alias)` | graph_id: bigint<br>alias: text | bigint | Find level ID by alias |
| `wh_update_level_height(level_id, new_height)` | level_id: bigint<br>new_height: real | void | Update level height |
| `wh_delete_level(level_id)` | level_id: bigint | void | Delete level (fails if cells exist) |

### Edge Management Functions

| Function | Parameters | Returns | Description |
|----------|------------|---------|-------------|
| `wh_create_edge(graph_id, node_a_id, node_b_id)` | graph_id: bigint<br>node_a_id: bigint<br>node_b_id: bigint | bigint | Create edge by node IDs |
| `wh_create_edge(graph_id, node_a_alias, node_b_alias)` | graph_id: bigint<br>node_a_alias: text<br>node_b_alias: text | bigint | Create edge by node aliases |
| `wh_delete_edge(edge_id)` | edge_id: bigint | void | Delete edge by ID |
| `wh_delete_edge_by_nodes(node_a_id, node_b_id)` | node_a_id: bigint<br>node_b_id: bigint | void | Delete edge by node pair |
| `wh_get_edges_by_node(node_id)` | node_id: bigint | TABLE | Get all edges connected to node |

### Node Query Functions

| Function | Parameters | Returns | Description |
|----------|------------|---------|-------------|
| `wh_get_node_by_alias(graph_id, alias)` | graph_id: bigint<br>alias: text | bigint | Find node ID by alias |
| `wh_list_nodes_by_graph(graph_id, [node_type])` | graph_id: bigint<br>node_type: node_type (optional) | TABLE | List nodes with optional type filter |
| `wh_get_depot_node_id(graph_id)` | graph_id: bigint | bigint | Get depot node ID |
| `wh_get_depot_position(graph_id)` | graph_id: bigint | TABLE(x, y) | Get depot coordinates |

### Node Update Functions

| Function | Parameters | Returns | Description |
|----------|------------|---------|-------------|
| `wh_update_node_position(node_id, x, y)` | node_id: bigint<br>x: real<br>y: real | void | Move node (not for cells) |
| `wh_update_depot_position(graph_id, x, y)` | graph_id: bigint<br>x: real<br>y: real | void | Move depot by graph ID |
| `wh_update_node_alias(node_id, alias)` | node_id: bigint<br>alias: text | void | Rename node (alias unique per graph) |
| `wh_update_node_tag_id(node_id, tag_id)` | node_id: bigint<br>tag_id: text | void | Update node tag ID |

### Node Deletion Functions

| Function | Parameters | Returns | Description |
|----------|------------|---------|-------------|
| `wh_delete_node(node_id)` | node_id: bigint | void | Delete node (CASCADE edges, blocks depot) |

### Routing Functions

| Function | Parameters | Returns | Description |
|----------|------------|---------|-------------|
| `wh_astar_shortest_path(graph_id, start_id, end_id, ...)` | graph_id: bigint<br>start_id: bigint<br>end_id: bigint<br>[directed]: boolean<br>[heuristic]: int<br>[factor]: float<br>[epsilon]: float | bigint[] | Find shortest path by node IDs |
| `wh_astar_shortest_path(graph_id, start_alias, end_alias, ...)` | graph_id: bigint<br>start_alias: text<br>end_alias: text<br>[routing params] | bigint[] | Find shortest path by aliases |
| `wh_astar_cost_matrix(graph_id, vids[], ...)` | graph_id: bigint<br>vids: bigint[]<br>[routing params] | TABLE | Distance matrix by node IDs |
| `wh_astar_cost_matrix(graph_id, aliases[], ...)` | graph_id: bigint<br>aliases: text[]<br>[routing params] | TABLE | Distance matrix by aliases |
| `wh_build_pgrouting_edges_query_3d(graph_id)` | graph_id: bigint | text | Helper: Generate pgRouting SQL query |

### Views Reference Table

| View | Purpose | Key Columns | Use Case |
|------|---------|-------------|----------|
| `wh_nodes_view` | All nodes with coordinates | id, type, alias, tag_id, x, y, graph_id | Display nodes on map |
| `wh_nodes_detailed_view` | Nodes with level details | + level_alias, level_height | Show cell levels |
| `wh_edges_view` | Edges with endpoint details | edge_id, node_a/b details, distance_2d | Visualize connections |
| `wh_graph_summary_view` | Graph statistics | node counts, edge_count, level_count | Dashboard/monitoring |

### Common Return Types

| Type | Structure | Example |
|------|-----------|---------|
| bigint | Single ID | `42` |
| void | No return value | - |
| bigint[] | Array of node IDs | `{1, 5, 7, 9}` |
| TABLE(x, y) | Coordinate pair | `(5.0, 10.0)` |
| TABLE(start_vid, end_vid, agg_cost) | Cost matrix | Multiple rows with distances |
| TABLE(id, name, ...) | Multi-column result | Query result set |

### Node Types Reference

| Type | Purpose | Coordinates | Special Attributes | Z-Height |
|------|---------|-------------|-------------------|----------|
| `depot` | Robot start/end | x, y | Always `__depot__` alias | 0 |
| `waypoint` | Navigation point | x, y | - | 0 |
| `conveyor` | Elevated transport | x, y | height | height |
| `shelf` | Storage unit | x, y | - | 0 |
| `cell` | Storage location | x,y from shelf; height from level | shelf_id, level_id | level.height |
