BEGIN;

-- --------------------
-- Enum type
-- --------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'pd_request_status') THEN
    CREATE TYPE pd_request_status AS ENUM ('cancelled', 'failed', 'queuing', 'in_progress', 'completed');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'assignment_status') THEN
    CREATE TYPE assignment_status AS ENUM ('cancelled', 'failed', 'in_progress', 'partially_completed', 'completed');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'task_status') THEN
    CREATE TYPE task_status AS ENUM ('cancelled', 'failed', 'on_another_delivery', 'pickup_en_route', 'picking_up', 'delivery_en_route', 'dropping_off', 'delivered');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'robot_status') THEN
    CREATE TYPE robot_status AS ENUM ('offline', 'idle', 'inactive', 'busy');
  END IF;
END $$;

--- --------------
--- wh_requests table
--- --------------
CREATE TABLE IF NOT EXISTS public.wh_requests (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

  pickup_cell_id   bigint NOT NULL REFERENCES public.wh_nodes(id) ON DELETE CASCADE,
  delivery_cell_id bigint NOT NULL REFERENCES public.wh_nodes(id) ON DELETE CASCADE,  

  status   pd_request_status NOT NULL DEFAULT 'queuing',
  priority int       NOT NULL DEFAULT 0,

  created_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT wh_requests_no_self_loop
    CHECK (pickup_cell_id <> delivery_cell_id),

  CONSTRAINT wh_requests_priority_range
    CHECK (priority BETWEEN 0 AND 100)
); 

-- TODO: request status change table

CREATE UNIQUE INDEX IF NOT EXISTS wh_requests_unique_pickup_when_pending
ON public.wh_requests (pickup_cell_id)
WHERE status = 'queuing';

CREATE TABLE IF NOT EXISTS wh_robots (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name           text NOT NULL UNIQUE,
  status         robot_status NOT NULL,
  endpoint       text NOT NULL,
  capacity  integer NOT NULL CHECK (capacity > 0),
  created_at     timestamptz NOT NULL DEFAULT now()
);

-- Don't touch this table manually
CREATE TABLE wh_robot_slots (
  robot_id   bigint NOT NULL REFERENCES wh_robots(id) ON DELETE CASCADE,
  slot       int    NOT NULL,
  request_id bigint NULL REFERENCES wh_requests(id) ON DELETE SET NULL,
  PRIMARY KEY (robot_id, slot),
  UNIQUE (request_id),
  CONSTRAINT wh_robot_slots_slot_nonneg CHECK (slot >= 0)
);

CREATE OR REPLACE FUNCTION wh_robots_sync_slots_with_capacity()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  blocked_slot int;
BEGIN
  -- Always ensure slots 0..NEW.capacity-1 exist (idempotent)
  INSERT INTO wh_robot_slots (robot_id, slot, request_id)
  SELECT NEW.id, s, NULL::bigint
  FROM generate_series(0, NEW.capacity - 1) AS s
  ON CONFLICT (robot_id, slot) DO NOTHING;

  -- On UPDATE, handle shrink cleanup (and validate)
  IF TG_OP = 'UPDATE' AND NEW.capacity < OLD.capacity THEN

    -- Block shrinking if any slot to be removed is occupied
    SELECT slot
      INTO blocked_slot
    FROM wh_robot_slots
    WHERE robot_id = NEW.id
      AND slot >= NEW.capacity
      AND request_id IS NOT NULL
    ORDER BY slot
    LIMIT 1;

    IF blocked_slot IS NOT NULL THEN
      RAISE EXCEPTION
        'Cannot shrink robot % capacity to %: slot % is occupied (request_id not NULL)',
        NEW.id, NEW.capacity, blocked_slot
        USING ERRCODE = '23514';
    END IF;

    -- Safe to delete trailing (now-out-of-range) slots
    DELETE FROM wh_robot_slots
    WHERE robot_id = NEW.id
      AND slot >= NEW.capacity;
  END IF;

  RETURN NEW;
END;
$$;

-- After INSERT: create initial slots
CREATE TRIGGER trg_wh_robots_sync_slots_ins
AFTER INSERT ON wh_robots
FOR EACH ROW
EXECUTE FUNCTION wh_robots_sync_slots_with_capacity();

-- After UPDATE of capacity: grow/shrink slots
CREATE TRIGGER trg_wh_robots_sync_slots_upd
AFTER UPDATE OF capacity ON wh_robots
FOR EACH ROW
EXECUTE FUNCTION wh_robots_sync_slots_with_capacity();

CREATE TABLE IF NOT EXISTS wh_assignments (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  robot_id      bigint REFERENCES wh_robots(id),
  original_seq  json   NOT NULL,
  provider      text   NOT NULL,
  status        assignment_status NOT NULL,
  priority      smallint NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS wh_tasks (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cell_id         bigint NOT NULL REFERENCES wh_cells(id),
  retrieve        boolean NOT NULL,
  status          task_status NOT NULL,
  assignment_id   bigint NOT NULL REFERENCES wh_assignments(id),
  seq_order       smallint NOT NULL,
  request_id      bigint REFERENCES wh_requests(id),
  created_at timestamptz NOT NULL DEFAULT now(),

  -- for the same assignment_id the seq_order must be unique
  CONSTRAINT wh_tasks_assignment_seqorder_uniq UNIQUE (assignment_id, seq_order)
);

COMMIT;