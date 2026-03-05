-- Not suggest

BEGIN;

DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
ALTER SCHEMA public OWNER TO postgres;

-- schema access
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT ALL   ON SCHEMA public TO postgres;

-- table access (existing tables)
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public
TO anon, authenticated, service_role;

-- sequences (serial/identity)
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public
TO anon, authenticated, service_role;

-- default privileges for future objects (IMPORTANT: runs as *current role*)
ALTER DEFAULT PRIVILEGES IN SCHEMA public
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES
TO anon, authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
GRANT USAGE, SELECT ON SEQUENCES
TO anon, authenticated, service_role;

GRANT USAGE ON SCHEMA extensions TO anon, authenticated, service_role;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA extensions
TO anon, authenticated, service_role;

COMMIT;