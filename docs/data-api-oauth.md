# Data API OAuth Deep-Dive

This document covers the Data API authentication chain (`mule-data-api`, port 8081):
how MuleSoft acquires and refreshes a Databricks OAuth token, how that token maps to
PostgREST operations, and the exact SP role setup that makes per-identity access work
without cloud_admin.

## OAuth Client-Credentials Acquisition

Mule's `oauth:client-credentials-grant-type` element in `DataApi_HTTP` handles everything:

```xml
<http:request-config name="DataApi_HTTP" basePath="${dataapi.basePath}">
    <http:request-connection host="${dataapi.host}" port="443" protocol="HTTPS"/>
    <http:authentication>
        <oauth:client-credentials-grant-type
            clientId="${databricks.client.id}"
            clientSecret="${databricks.client.secret}"
            tokenUrl="https://${databricks.host}/oidc/v1/token"
            scopes="all-apis"/>
    </http:authentication>
</http:request-config>
```

**Token URL:** `https://<workspace-host>/oidc/v1/token`
**Grant type:** `client_credentials`
**Scope:** `all-apis` (required by the Databricks workspace OAuth server)

The module:
1. Fetches a token on first use and caches it.
2. Automatically refreshes before the 1-hour expiry (the `expires_in` field in the
   token response governs the refresh window).
3. Retries on HTTP 401 with a fresh token (refresh-on-401 behaviour).

No custom scheduler or Object Store is needed for the Data API path — the OAuth module
owns the whole lifecycle.

### curl Equivalent

```bash
# Set these from config-local.yaml / environment — never hardcode
WORKSPACE_HOST="<your-workspace-host>"
SP_CLIENT_ID="<SP_CLIENT_ID>"
SP_CLIENT_SECRET="<SP_CLIENT_SECRET>"
DATA_API_URL="<DATA_API_URL>"   # see infra/connection-facts.md

# Acquire token (Basic auth = client_id:client_secret)
BEARER=$(curl -s \
  --request POST "https://${WORKSPACE_HOST}/oidc/v1/token" \
  --data "grant_type=client_credentials&scope=all-apis" \
  -u "${SP_CLIENT_ID}:${SP_CLIENT_SECRET}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")

# Verify: list customers
curl -H "Authorization: Bearer ${BEARER}" \
  "${DATA_API_URL}/demo/customers?order=id"
```

This is the exact pattern used by `infra/smoke-test.sh` (Chain 2 block).

## PostgREST Verb Mapping

The Lakebase Data API is a PostgREST proxy. Table paths take the form
`<DATA_API_URL>/<schema>/<table>`. Filtering uses PostgREST's operator syntax
(`col=eq.value`, `col=gt.value`, etc.).

| CRUD operation | HTTP method | Path + params                                     | Headers                              |
|----------------|-------------|---------------------------------------------------|--------------------------------------|
| List all       | `GET`       | `/demo/customers?order=id`                        | `Authorization: Bearer {token}`      |
| Read by id     | `GET`       | `/demo/customers?id=eq.{id}`                      | `Authorization: Bearer {token}`      |
| Create         | `POST`      | `/demo/customers`                                 | + `Prefer: return=representation`    |
| Update by id   | `PATCH`     | `/demo/customers?id=eq.{id}`                      | + `Prefer: return=representation`    |
| Delete by id   | `DELETE`    | `/demo/customers?id=eq.{id}`                      | `Authorization: Bearer {token}`      |

`Prefer: return=representation` instructs PostgREST to return the created/updated row
rather than an empty 201/204. The Mule flows set this header on POST and PATCH.

### Full curl Matrix

```bash
# Create
curl -s -X POST "${DATA_API_URL}/demo/customers" \
  -H "Authorization: Bearer ${BEARER}" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d '{"name":"Test User","email":"test@example.com","tier":"standard"}'

# Read by id
curl -s "${DATA_API_URL}/demo/customers?id=eq.1" \
  -H "Authorization: Bearer ${BEARER}"

# Update by id
curl -s -X PATCH "${DATA_API_URL}/demo/customers?id=eq.1" \
  -H "Authorization: Bearer ${BEARER}" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d '{"tier":"gold"}'

# Delete by id
curl -s -X DELETE "${DATA_API_URL}/demo/customers?id=eq.1" \
  -H "Authorization: Bearer ${BEARER}"
```

## SP Role Setup — The Critical Lesson

> **This is the most non-obvious requirement of the entire demo.**

The Lakebase Data API uses PostgREST. For every incoming request, PostgREST connects as
the `authenticator` Postgres role and then runs `SET ROLE "<role>"` to assume the
caller's identity. For Databricks-issued JWTs, the proxy extracts the `.sub` claim
(which equals the SP's client ID UUID) and uses that as the target role name.

**The SP's Postgres role must be created via the `databricks_auth` extension, not via
plain SQL or the `databricks postgres create-role` CLI.**

### The Correct Path: `databricks_create_role()`

```sql
-- infra/data-api-role.sql — run as the Lakebase project owner

CREATE EXTENSION IF NOT EXISTS databricks_auth;

-- Creates the SP role AND registers the Lakebase identity mapping
-- (auth_method=LAKEBASE_OAUTH_V1, identity_type=SERVICE_PRINCIPAL).
-- The calling user receives ADMIN OPTION on the new role.
SELECT databricks_create_role('<SP_CLIENT_ID>', 'SERVICE_PRINCIPAL');

-- Grant the role to authenticator (works because of ADMIN OPTION above).
GRANT "<SP_CLIENT_ID>" TO authenticator;

-- Grant the SP demo schema access.
GRANT USAGE ON SCHEMA demo TO "<SP_CLIENT_ID>";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA demo TO "<SP_CLIENT_ID>";
GRANT USAGE ON ALL SEQUENCES IN SCHEMA demo TO "<SP_CLIENT_ID>";
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA demo TO "<SP_CLIENT_ID>";
```

Substitute `<SP_CLIENT_ID>` with the actual UUID at apply time:

```bash
sed 's/<SP_CLIENT_ID>/<SP_CLIENT_ID>/g' infra/data-api-role.sql \
  | PGPASSWORD="$(databricks postgres generate-database-credential \
      projects/mulesoft-lakebase-demo/branches/production/endpoints/primary \
      --profile mulesoft-lakebase-demo -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')" \
    psql "host=${PG_HOST} user=${PG_USER} dbname=databricks_postgres sslmode=require"
```

Or run the full automated setup:

```bash
bash infra/data-api-setup.sh mulesoft-lakebase-demo <SP_CLIENT_ID> mulesoft-lakebase-demo
```

### Why NOT `databricks postgres create-role`

The `databricks postgres create-role` CLI command creates the Postgres role as a
**control-plane-owned** object:

- The project creator gets **no ADMIN OPTION** on the new role.
- Any attempt to `GRANT "<SP_UUID>" TO authenticator` fails with
  `ERROR: permission denied to grant role`.
- The role is registered as `NO_LOGIN` / `IDENTITY_TYPE_UNSPECIFIED` and cannot be
  upgraded via `update-role`.

Two alternatives were investigated and ruled out:

1. **Plain `CREATE ROLE "<SP_UUID>"`** — the control plane auto-registers the role on
   first token presentation but does so as `NO_LOGIN / IDENTITY_TYPE_UNSPECIFIED`, which
   blocks the GRANT to `authenticator` the same way.
2. **Shared anon role via `db_anon_role`** — the Databricks Data API proxy bypasses
   PostgREST's `jwt_role_claim_key` and `db_anon_role` settings for Databricks-issued
   JWTs. It always routes the request to the Lakebase-registered Postgres role directly,
   so there is no shared-role fallback to reach.

**`databricks_create_role()` is the only supported no-cloud_admin path.**

## Data API Configuration

The current live configuration (see `infra/connection-facts.md`):

| Parameter            | Value                          |
|----------------------|--------------------------------|
| `db_schemas`         | `["demo", "public"]`           |
| `jwt_role_claim_key` | `.sub`                         |
| `db_anon_role`       | `demo_api`                     |

`jwt_role_claim_key = ".sub"` tells PostgREST which claim to extract for `SET ROLE`.
Databricks SP tokens carry the SP's client ID in `.sub`, so this maps directly to the
role name created by `databricks_create_role()`.
