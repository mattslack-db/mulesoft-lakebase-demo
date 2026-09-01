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

### Data API Configuration (as of rebuild)

| Parameter | Value |
|-----------|-------|
| `db_schemas` | `["demo", "public"]` |
| `jwt_role_claim_key` | `.sub` |
| `db_anon_role` | `anonymous` |

### Known Blocker: authenticator role membership

The Data API chain reaches HTTP 403 with `"permission denied to set role \"7a31531d-...\""`.

PostgREST connects as `authenticator` and calls `SET LOCAL ROLE "7a31531d-..."` (the SP client ID,
extracted from the `.sub` JWT claim). This requires `authenticator` to be a member of the SP's
Postgres role.

The grant `GRANT "7a31531d-..." TO authenticator` fails for all project-creator access levels:
- Plain GRANT: `ERROR: permission denied to grant role "7a31531d-..." — Only roles with the ADMIN option may grant this role`
- Via `SET ROLE databricks_superuser`: `ERROR: permission denied to set role "databricks_superuser"`
  (matt.slack is a member of `databricks_superuser` in pg_auth_members with `admin_option: false`)

The Databricks control plane (`cloud_admin`, `databricks_control_plane`) must run this grant.
The `databricks postgres create-role` API does NOT automatically grant the SP role to `authenticator`
even when `auth_method: LAKEBASE_OAUTH_V1` is specified. This is a Lakebase product gap.

**Unblock path**: A Databricks workspace admin or the Lakebase product team needs to run:
```sql
-- As cloud_admin or via Databricks support
GRANT "7a31531d-df0c-484f-af00-acd8a4f4e461" TO authenticator;
```
Or the `create-role` API should be updated to automatically GRANT SP roles to `authenticator`.
