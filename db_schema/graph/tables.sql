BEGIN;

-- conveyor <- waypoint -> shelf -> cell
--               -> depot
-- --------------------
-- Graphs
-- --------------------
CREATE TABLE IF NOT EXISTS public.wh_graphs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name text NOT NULL UNIQUE,
  map_url text,
  map_res real,

  created_at timestamptz NOT NULL DEFAULT now()
);

-- --------------------
-- Nodes
-- --------------------
CREATE TABLE IF NOT EXISTS public.wh_nodes (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  type node_type NOT NULL,
  alias text,  -- Optional: NULL aliases are allowed; multiple NULLs per graph permitted
  tag_id text, -- Optional: NULL tag_ids are allowed; multiple NULLs per graph permitted
  graph_id bigint NOT NULL REFERENCES public.wh_graphs(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT wh_nodes_graph_id_id_unique UNIQUE (graph_id, id),
  CONSTRAINT wh_nodes_graph_id_alias_unique UNIQUE (graph_id, alias),  -- Note: NULL not enforced by UNIQUE
  CONSTRAINT wh_nodes_graph_id_tag_id_unique UNIQUE (graph_id, tag_id),  -- Note: NULL not enforced by UNIQUE
  CONSTRAINT wh_nodes_depot_alias_rule CHECK (type <> 'depot' OR alias='__depot__')
);

CREATE TABLE IF NOT EXISTS public.wh_depot_nodes (
  id bigint PRIMARY KEY REFERENCES public.wh_nodes(id) ON DELETE CASCADE,
  x real NOT NULL,
  y real NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.wh_waypoint_nodes (
  id bigint PRIMARY KEY REFERENCES public.wh_nodes(id) ON DELETE CASCADE,
  x real NOT NULL,
  y real NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.wh_conveyor_nodes (
  id bigint PRIMARY KEY REFERENCES public.wh_nodes(id) ON DELETE CASCADE,
  x real NOT NULL,
  y real NOT NULL,
  height real NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.wh_shelf_nodes (
  id bigint PRIMARY KEY REFERENCES public.wh_nodes(id) ON DELETE CASCADE,
  x real NOT NULL,
  y real NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.wh_levels (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  height real NOT NULL,
  alias text NOT NULL,
  graph_id bigint NOT NULL REFERENCES public.wh_graphs(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT wh_levels_graph_level_unique UNIQUE (graph_id, alias),
  CONSTRAINT wh_levels_height_non_negative CHECK (height >= 0)
);

CREATE TABLE IF NOT EXISTS public.wh_cell_nodes (
  id bigint PRIMARY KEY REFERENCES public.wh_nodes(id) ON DELETE CASCADE,
  shelf_id bigint NOT NULL REFERENCES public.wh_shelf_nodes(id) ON DELETE CASCADE,
  level_id bigint NOT NULL REFERENCES public.wh_levels(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- --------------------
-- Edges (UNDIRECTED; stored once)
-- Enforces: endpoints belong to the same graph_id
-- --------------------
CREATE TABLE IF NOT EXISTS public.wh_edges (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  graph_id bigint NOT NULL REFERENCES public.wh_graphs(id) ON DELETE CASCADE,

  node_a_id bigint NOT NULL,
  node_b_id bigint NOT NULL,

  created_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT wh_edges_no_self_loop CHECK (node_a_id <> node_b_id),
  CONSTRAINT wh_edges_normalized CHECK (node_a_id < node_b_id),  -- Enforce consistent storage

  CONSTRAINT wh_edges_node_a_same_graph_fk
    FOREIGN KEY (graph_id, node_a_id)
    REFERENCES public.wh_nodes (graph_id, id)
    ON DELETE CASCADE,

  CONSTRAINT wh_edges_node_b_same_graph_fk
    FOREIGN KEY (graph_id, node_b_id)
    REFERENCES public.wh_nodes (graph_id, id)
    ON DELETE CASCADE
);

COMMIT;
