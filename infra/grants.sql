-- infra/grants.sql — JDBC / direct-Postgres path only.
-- This file sets up the direct-login role for the mule-jdbc app (Chain 2 in the docs).
--
-- IMPORTANT: This is for the JDBC / direct-Postgres path ONLY.
-- The Data API (PostgREST) path must NOT use plain CREATE ROLE or
-- `databricks postgres create-role` — it requires the databricks_auth extension
-- (databricks_create_role(...)). See infra/data-api-role.sql for that path.

-- SP identity = its application/client id (M2M). Role name must match the identity.
-- (JDBC / direct-Postgres path only — see header comment above.)
CREATE ROLE "<SP_CLIENT_ID>" LOGIN;
GRANT USAGE ON SCHEMA demo TO "<SP_CLIENT_ID>";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA demo TO "<SP_CLIENT_ID>";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA demo TO "<SP_CLIENT_ID>";
ALTER DEFAULT PRIVILEGES IN SCHEMA demo
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "<SP_CLIENT_ID>";
