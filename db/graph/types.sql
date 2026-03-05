BEGIN;

-- --------------------
-- Enum type
-- --------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'node_type') THEN
    CREATE TYPE node_type AS ENUM ('waypoint', 'conveyor', 'shelf', 'cell', 'depot');
  END IF;
END $$;

COMMIT;
