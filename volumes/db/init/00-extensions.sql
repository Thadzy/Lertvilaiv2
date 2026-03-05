-- Enable pgRouting in the extensions schema (required by the warehouse graph functions)
CREATE EXTENSION IF NOT EXISTS pgrouting SCHEMA extensions CASCADE;
