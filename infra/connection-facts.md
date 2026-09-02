# MuleSoft ↔ Lakebase Demo — Connection Facts

Non-secret connection values for the demo environment.
**Do not add secrets to this file.** Credentials live in `config-local.yaml` (git-ignored).

## Workspace

| Key | Value |
|-----|-------|
| `PROFILE` | `mulesoft-lakebase-demo` |
| `WORKSPACE_HOST` | `<WORKSPACE_HOST>` |

## Service Principal (OAuth M2M)

| Key | Value |
|-----|-------|
| `SP_DISPLAY_NAME` | `mulesoft-lakebase-demo-sp` |
| `SP_CLIENT_ID` | `<SP_CLIENT_ID>` |

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
| `PG_HOST` | `<PG_HOST>` |
| `PG_DATABASE` | `databricks_postgres` |

## Data API

| Key | Value |
|-----|-------|
| `DATA_API_URL` | `https://<PG_HOST>/api/2.0/workspace/<WORKSPACE_ID>/rest/databricks_postgres` |

> Tables are addressed as `<DATA_API_URL>/<schema>/<table>` (PostgREST convention).
> Example: `<DATA_API_URL>/demo/customers`

### Current Data API Configuration

| Parameter | Value |
|-----------|-------|
| `db_schemas` | `["demo", "public"]` |
| `jwt_role_claim_key` | `.sub` |
| `db_anon_role` | `demo_api` |

### Lakebase Role Registry

| Role ID | postgres_role | auth_method | Notes |
|---------|--------------|-------------|-------|
| `sp-mulesoft-demo` | `7a31531d-...` | `LAKEBASE_OAUTH_V1` | SP M2M identity mapping |
| `matt-slack` | `matt.slack@databricks.com` | `LAKEBASE_OAUTH_V1` | Project owner |
| `rol-f31p-r8lpvzb82s` | `authenticator` | `PG_PASSWORD_SCRAM_SHA_256` | PostgREST connector role |

### Known Blocker: authenticator → SP role membership (confirmed impossible without cloud_admin)

**Symptom:** HTTP 403 `"permission denied to set role \"7a31531d-...\""` on Data API calls.

**Root cause:** The Databricks Data API proxy validates the SP JWT against the Lakebase role registry
(requires `LAKEBASE_OAUTH_V1` for the SP identity), then **ignores `jwt_role_claim_key`** and directly
routes to the Lakebase role's `postgres_role` field (always = SP client_id UUID for SP identities).
PostgREST executes `SET LOCAL ROLE "7a31531d-..."`. This requires `authenticator` to be a member.

**All workaround paths tested and failed:**

| Approach | Result |
|----------|--------|
| `GRANT "7a31531d-..." TO authenticator` as matt.slack | ERROR: no ADMIN OPTION (CP-owned role) |
| `SET ROLE databricks_superuser; GRANT ...` | ERROR: permission denied to set role (admin_option=f) |
| Create SP Postgres role as matt.slack first (ADMIN OPTION) → then `create-role` | CP auto-registers manually-created role as `NO_LOGIN/IDENTITY_TYPE_UNSPECIFIED` (not updatable), then `create-role` fails "role with that name already exists" |
| Change `jwt_role_claim_key` to `.role` (absent in SP JWT) → PostgREST anon fallback | Proxy bypasses `jwt_role_claim_key` for Databricks tokens; still routes to `7a31531d-...` |
| `create-role --json '{"spec":{"postgres_role":"demo_api",...}}'` | ERROR: `Identity 'demo_api' not found` — SP postgres_role must equal SP client_id UUID |
| `update-role` to change `auth_method`/`identity_type`/`postgres_role` | ERROR: `Unknown field path in update_mask` — these fields are immutable after creation |

**Key architectural finding:** The Databricks Data API proxy enforces `postgres_role == SP_CLIENT_ID`
for SERVICE_PRINCIPAL Lakebase roles. `jwt_role_claim_key` is only effective for non-Databricks
(external IdP) tokens, not for Databricks-issued JWTs. For Databricks SP tokens, the role is always
the `postgres_role` from the Lakebase role spec, and that role is always CP-owned.

**Shared Postgres role `demo_api`:** Created as matt.slack (ADMIN OPTION), demo CRUD granted,
`authenticator` is a member. This role exists and is ready — if cloud_admin runs the grant or the
Lakebase product team fixes `create-role` to wire up `authenticator` membership, the per-identity
path immediately works. `demo_api` is also available as a future shared-auth fallback if the product
supports that pattern.

**Unblock path (cloud_admin required):**
```sql
-- Run as cloud_admin or via Databricks support
GRANT "<SP_CLIENT_ID>" TO authenticator;
```
Or: the `create-role` API should automatically GRANT SP roles to `authenticator` when
`auth_method: LAKEBASE_OAUTH_V1` is set. This is a confirmed Lakebase product gap.
