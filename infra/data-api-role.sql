-- data-api-role.sql — Create the SP Postgres role for the Lakebase Data API.
--
-- Uses the databricks_auth extension's databricks_create_role() function, which:
--   1. Creates the SP's Postgres role and registers it as a Lakebase identity mapping
--      (auth_method=LAKEBASE_OAUTH_V1, identity_type=SERVICE_PRINCIPAL) atomically.
--   2. Grants the current session user ADMIN OPTION on the new role, so the
--      subsequent GRANT to authenticator succeeds without superuser.
--
-- Run as the project owner (generate-database-credential token):
--   PGPASSWORD=<token> psql "host=<PG_HOST> user=<PG_USER> dbname=databricks_postgres sslmode=require" \
--     -f infra/data-api-role.sql
--
-- Substitute <SP_CLIENT_ID> with the actual SP client_id UUID before running.
-- Committed file keeps the placeholder — substitute at apply time via sed:
--   sed 's/<SP_CLIENT_ID>/7a31531d-.../g' infra/data-api-role.sql | psql ...
--
-- Prerequisites: infra/schema.sql and infra/seed.sql must have been applied.
-- Idempotency: databricks_create_role errors if the role exists; the GRANT/USAGE
--   statements are safe to re-run (IF NOT EXISTS / OR REPLACE not needed for GRANT).

CREATE EXTENSION IF NOT EXISTS databricks_auth;

-- Create the SP's Postgres role via the sanctioned extension function.
-- DO NOT use plain CREATE ROLE or databricks postgres create-role here —
-- see infra/data-api-setup.sh header comment for why those paths fail.
SELECT databricks_create_role('<SP_CLIENT_ID>', 'SERVICE_PRINCIPAL');

-- Allow PostgREST (connects as 'authenticator') to assume this role.
-- Succeeds because databricks_create_role() grants the calling user ADMIN OPTION.
GRANT "<SP_CLIENT_ID>" TO authenticator;

-- Grant the SP demo schema access.
GRANT USAGE ON SCHEMA demo TO "<SP_CLIENT_ID>";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA demo TO "<SP_CLIENT_ID>";
GRANT USAGE ON ALL SEQUENCES IN SCHEMA demo TO "<SP_CLIENT_ID>";
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA demo TO "<SP_CLIENT_ID>";
