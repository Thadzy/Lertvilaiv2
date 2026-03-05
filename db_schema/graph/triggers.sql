BEGIN;

-- Graph insert -> create depot
CREATE OR REPLACE FUNCTION public.wh_graphs_insert_depot()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_depot_id bigint;
BEGIN
  -- Create depot node; if alias "__depot__" is already used in this graph,
  -- UNIQUE(graph_id, alias) will throw, so catch and explain.
  BEGIN
    INSERT INTO public.wh_nodes (type, alias, graph_id)
    VALUES ('depot', '__depot__', NEW.id)
    RETURNING id INTO v_depot_id;
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION
        'Cannot auto-create depot for graph_id=% because alias "__depot__" is already used in this graph.',
        NEW.id;
  END;

  -- OPTIONAL: ensure depot has coordinates row so routing can include it.
  -- Remove this block if you want to force users to set x/y explicitly.
  INSERT INTO public.wh_depot_nodes (id, x, y)
  VALUES (v_depot_id, 0::real, 0::real)
  ON CONFLICT (id) DO NOTHING;

  RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS wh_graphs_insert_depot_trg ON public.wh_graphs;
CREATE TRIGGER wh_graphs_insert_depot_trg
AFTER INSERT ON public.wh_graphs
FOR EACH ROW EXECUTE FUNCTION public.wh_graphs_insert_depot();


-- Node update/delete -> lock depot
CREATE OR REPLACE FUNCTION public.wh_nodes_lock_depot()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.type = 'depot' THEN
    IF TG_OP = 'DELETE' THEN
      -- Allow deletion if graph is being deleted (CASCADE scenario)
      -- Block only direct depot deletion
      IF EXISTS (SELECT 1 FROM public.wh_graphs WHERE id = OLD.graph_id) THEN
        RAISE EXCEPTION 'depot cannot be deleted';
      END IF;
    ELSIF TG_OP = 'UPDATE' THEN
      IF NEW.type <> 'depot' THEN
        RAISE EXCEPTION 'depot type cannot change';
      END IF;

      IF NEW.alias <> '__depot__' THEN
        RAISE EXCEPTION 'depot alias cannot change (must be "__depot__")';
      END IF;

      IF NEW.graph_id <> OLD.graph_id THEN
        RAISE EXCEPTION 'depot graph_id cannot change';
      END IF;
    END IF;
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;

  RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS wh_nodes_lock_depot_trg ON public.wh_nodes;
CREATE TRIGGER wh_nodes_lock_depot_trg
BEFORE UPDATE OR DELETE ON public.wh_nodes
FOR EACH ROW EXECUTE FUNCTION public.wh_nodes_lock_depot();


-- Cell cross-graph validation -> ensure shelf and level belong to same graph
CREATE OR REPLACE FUNCTION public.wh_cell_nodes_validate_graph()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_cell_graph_id bigint;
  v_shelf_graph_id bigint;
  v_level_graph_id bigint;
BEGIN
  -- Get the graph_id of the cell node
  SELECT graph_id INTO v_cell_graph_id
  FROM public.wh_nodes
  WHERE id = NEW.id;

  IF v_cell_graph_id IS NULL THEN
    RAISE EXCEPTION 'Cell node % does not exist in wh_nodes', NEW.id;
  END IF;

  -- Get the graph_id of the shelf
  SELECT n.graph_id INTO v_shelf_graph_id
  FROM public.wh_nodes n
  JOIN public.wh_shelf_nodes s ON s.id = n.id
  WHERE n.id = NEW.shelf_id;

  IF v_shelf_graph_id IS NULL THEN
    RAISE EXCEPTION 'Shelf % does not exist', NEW.shelf_id;
  END IF;

  -- Get the graph_id of the level
  SELECT graph_id INTO v_level_graph_id
  FROM public.wh_levels
  WHERE id = NEW.level_id;

  IF v_level_graph_id IS NULL THEN
    RAISE EXCEPTION 'Level % does not exist', NEW.level_id;
  END IF;

  -- Validate all belong to the same graph
  IF v_shelf_graph_id <> v_cell_graph_id THEN
    RAISE EXCEPTION 'Shelf % belongs to graph %, but cell % belongs to graph %',
      NEW.shelf_id, v_shelf_graph_id, NEW.id, v_cell_graph_id;
  END IF;

  IF v_level_graph_id <> v_cell_graph_id THEN
    RAISE EXCEPTION 'Level % belongs to graph %, but cell % belongs to graph %',
      NEW.level_id, v_level_graph_id, NEW.id, v_cell_graph_id;
  END IF;

  RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS wh_cell_nodes_validate_graph_trg ON public.wh_cell_nodes;
CREATE TRIGGER wh_cell_nodes_validate_graph_trg
BEFORE INSERT OR UPDATE ON public.wh_cell_nodes
FOR EACH ROW EXECUTE FUNCTION public.wh_cell_nodes_validate_graph();

COMMIT;
