# MuleSoft ↔ Lakebase Demo — Connection Facts

Non-secret connection values for the demo environment.
**Do not add secrets to this file.** Credentials live in `config-local.yaml` (git-ignored).

## Workspace

| Key | Value |
|-----|-------|
| `PROFILE` | `mulesoft-lakebase-demo` |
| `WORKSPACE_HOST` | `fe-sandbox-mulesoft-lakebase-demo.cloud.databricks.com` |

## Service Principal (OAuth M2M)

| Key | Value |
|-----|-------|
| `SP_DISPLAY_NAME` | `mulesoft-lakebase-demo-sp` |
| `SP_CLIENT_ID` | `7a31531d-df0c-484f-af00-acd8a4f4e461` |

> `SP_CLIENT_SECRET` — stored only in `config-local.yaml`, never here.

## Lakebase Project

| Key | Value |
|-----|-------|
| `PROJECT_ID` | `mulesoft-lakebase-demo` |
| `BRANCH_ID` | `production` |

## Lakebase Endpoint

| Key | Value |
|-----|-------|
| `ENDPOINT_ID` | `primary` |
| `ENDPOINT_PATH` | `projects/mulesoft-lakebase-demo/branches/production/endpoints/primary` |
| `PG_HOST` | `ep-round-haze-d1ur4ljy.database.us-west-2.cloud.databricks.com` |
| `PG_DATABASE` | `databricks_postgres` |

## Data API

| Key | Value |
|-----|-------|
| `DATA_API_URL` | `https://ep-round-haze-d1ur4ljy.database.us-west-2.cloud.databricks.com/api/2.0/workspace/7474647152304469/rest/databricks_postgres` |

> Tables are addressed as `<DATA_API_URL>/<schema>/<table>` (PostgREST convention).
> Example: `<DATA_API_URL>/demo/customers`

### Current Data API Configuration

| Parameter | Value |
|-----------|-------|
| `db_schemas` | `["demo", "public"]` |
| `jwt_role_claim_key` | `.sub` |
| `db_anon_role` | `demo_api` |

### Status: WORKING — per-identity, no cloud_admin required

Both OAuth chains are confirmed working via `infra/smoke-test.sh`:
```
✓ JDBC/psql auth chain OK
✓ Data API auth chain OK
```

The Data API chain uses per-identity Postgres role assignment: the SP's bearer token (OAuth
`client_credentials` flow) is validated by the Databricks proxy, which routes the request to
the SP's Postgres role (`7a31531d-...`) via PostgREST. The role has USAGE on `demo` schema and
CRUD on `demo.customers`.

### Key: databricks_auth Extension

The correct setup mechanism is the `databricks_create_role()` function from the
`databricks_auth` Postgres extension (available on all Lakebase instances):

```sql
CREATE EXTENSION IF NOT EXISTS databricks_auth;
SELECT databricks_create_role('<SP_CLIENT_ID>', 'SERVICE_PRINCIPAL');
GRANT "<SP_CLIENT_ID>" TO authenticator;
-- then grant schema CRUD
```

This is the ONLY no-cloud_admin path. It creates the role such that the calling user has
ADMIN OPTION → can grant it to `authenticator`. It also registers the Lakebase identity
mapping (`LAKEBASE_OAUTH_V1`, `SERVICE_PRINCIPAL`) atomically — no separate
`databricks postgres create-role` CLI call needed.

See `infra/data-api-role.sql` for the reproducible SQL and `infra/data-api-setup.sh`
for the full automated setup script.

### Why NOT `databricks postgres create-role` (CLI path)

The CLI path creates CP-owned Postgres roles with no ADMIN OPTION for the project creator:
- Plain `CREATE ROLE "SP_UUID"` as matt.slack → CP auto-registers as `NO_LOGIN / IDENTITY_TYPE_UNSPECIFIED`; can't be upgraded via `update-role`
- `databricks postgres create-role` → CP-owned role; GRANT to authenticator fails: `permission denied`

The Databricks Data API proxy also bypasses PostgREST's `jwt_role_claim_key` / `db_anon_role`
for Databricks-issued JWTs — shared-role fallback is not an achievable alternative.
