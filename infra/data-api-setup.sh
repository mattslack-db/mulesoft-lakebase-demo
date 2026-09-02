#!/usr/bin/env bash
# data-api-setup.sh — Reproducible Data API setup for the mulesoft-lakebase-demo project.
#
# Enables the Lakebase PostgREST Data API with per-identity SP OAuth M2M
# (client-credentials) authentication via the databricks_auth extension.
#
# Steps performed:
#   Step 1: Enable the Data API (POST) with db_schemas=["demo","public"].
#   Step 2: Verify/set jwt_role_claim_key=".sub" (SP tokens carry client_id in .sub).
#   Step 3: Use databricks_create_role() from the databricks_auth extension to create
#           the SP's Postgres role in a way that the current user can grant it to
#           authenticator. GRANT to authenticator. Grant demo schema CRUD.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY databricks_create_role() AND NOT databricks postgres create-role
# ─────────────────────────────────────────────────────────────────────────────
# `databricks postgres create-role` (CLI/control-plane path) creates the Postgres
# role as a CP-owned role. The project creator gets no ADMIN OPTION → cannot grant
# it to authenticator → Data API returns 403 "permission denied to set role".
#
# `databricks_create_role(uuid, 'SERVICE_PRINCIPAL')` (databricks_auth extension)
# creates the role such that the current psql session user (e.g. matt.slack) has
# ADMIN OPTION → can grant it to authenticator. It also registers the Lakebase role
# with auth_method=LAKEBASE_OAUTH_V1 automatically — no separate CLI create-role call.
#
# Alternative paths investigated and ruled out (see infra/connection-facts.md):
#   - `CREATE ROLE "SP_UUID"` then `create-role`: CP auto-registers as NO_LOGIN/immutable
#   - Shared anon-role via db_anon_role: Databricks proxy bypasses jwt_role_claim_key
#     for Databricks-issued JWTs; always routes to the Lakebase postgres_role directly
# ─────────────────────────────────────────────────────────────────────────────
#
# Usage:
#   bash infra/data-api-setup.sh <PROJECT_ID> <SP_CLIENT_ID> <PROFILE> [<WORKSPACE_HOST>]
#
#   Or via env vars:
#   PROJECT_ID=mulesoft-lakebase-demo SP_CLIENT_ID=<uuid> PROFILE=mulesoft-lakebase-demo \
#     bash infra/data-api-setup.sh
#
# Does NOT read or print secrets. SP client_id is a non-secret identifier.
# Workspace host is inferred from the databricks profile if not supplied.
#
# Requires:
#   - databricks CLI (authenticated, profile with workspace admin)
#   - curl, python3, psql
#   - The Lakebase project and production branch must already exist
#   - infra/schema.sql and infra/seed.sql must have been applied first
set -euo pipefail

# ---------------------------------------------------------------------------
# Arguments / env
# ---------------------------------------------------------------------------
PROJECT_ID="${1:-${PROJECT_ID:-}}"
SP_CLIENT_ID="${2:-${SP_CLIENT_ID:-}}"
PROFILE="${3:-${PROFILE:-}}"
WORKSPACE_HOST="${4:-${WORKSPACE_HOST:-}}"

if [[ -z "${PROJECT_ID}" || -z "${SP_CLIENT_ID}" || -z "${PROFILE}" ]]; then
  echo "ERROR: Required: PROJECT_ID, SP_CLIENT_ID, PROFILE" >&2
  echo "Usage: bash infra/data-api-setup.sh <PROJECT_ID> <SP_CLIENT_ID> <PROFILE> [<WORKSPACE_HOST>]" >&2
  exit 1
fi

BRANCH_ID="production"
DATABASE_ID="databricks-postgres"
BRANCH_PATH="projects/${PROJECT_ID}/branches/${BRANCH_ID}"
DATA_API_PATH="${BRANCH_PATH}/databases/${DATABASE_ID}/data-api"

# Resolve workspace host from CLI profile if not provided
if [[ -z "${WORKSPACE_HOST}" ]]; then
  WORKSPACE_HOST=$(databricks auth describe --profile "${PROFILE}" -o json 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('details',{}).get('host','').lstrip('https://'))" 2>/dev/null || true)
fi

if [[ -z "${WORKSPACE_HOST}" ]]; then
  WORKSPACE_HOST=$(python3 -c "
import configparser, os
cfg = configparser.ConfigParser()
cfg.read(os.path.expanduser('~/.databrickscfg'))
print(cfg.get('${PROFILE}', 'host', fallback='').lstrip('https://').rstrip('/'))
")
fi

if [[ -z "${WORKSPACE_HOST}" ]]; then
  echo "ERROR: Could not determine WORKSPACE_HOST. Pass it as arg 4 or set env var." >&2
  exit 1
fi

echo "=== Data API Setup ==="
echo "  PROJECT_ID:      ${PROJECT_ID}"
echo "  SP_CLIENT_ID:    ${SP_CLIENT_ID}"
echo "  PROFILE:         ${PROFILE}"
echo "  WORKSPACE_HOST:  ${WORKSPACE_HOST}"
echo ""

# ---------------------------------------------------------------------------
# Get workspace auth token (no secrets printed)
# ---------------------------------------------------------------------------
WS_TOKEN=$(databricks auth token --profile "${PROFILE}" -o json 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")

# ---------------------------------------------------------------------------
# Postgres connection details (needed for Steps 2+3)
# ---------------------------------------------------------------------------
EP_PATH="${BRANCH_PATH}/endpoints/primary"
PG_TOKEN=$(databricks postgres generate-database-credential "${EP_PATH}" \
  --profile "${PROFILE}" -o json \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['token'])")
PG_HOST=$(databricks postgres get-endpoint "${EP_PATH}" --profile "${PROFILE}" -o json \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['status']['hosts']['host'])")
PG_USER=$(databricks current-user me --profile "${PROFILE}" -o json \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['userName'])")
PSQL="${PSQL:-psql}"

# ---------------------------------------------------------------------------
# Step 1: Enable the Data API (or verify it is already enabled)
# ---------------------------------------------------------------------------
echo "--- Step 1: Enable Data API with db_schemas=[\"demo\",\"public\"] ---"
EXISTING=$(curl -s -w "\n%{http_code}" \
  -H "Authorization: Bearer ${WS_TOKEN}" \
  "https://${WORKSPACE_HOST}/api/2.0/postgres/${DATA_API_PATH}")
HTTP_STATUS=$(echo "${EXISTING}" | tail -n1)
EXISTING_BODY=$(echo "${EXISTING}" | sed '$d')

if [[ "${HTTP_STATUS}" == "200" ]]; then
  CURRENT_SCHEMAS=$(echo "${EXISTING_BODY}" | python3 -c "
import json,sys; d=json.load(sys.stdin)
r = d.get('response', d)
schemas = r.get('status',{}).get('db_schemas', r.get('spec',{}).get('db_schemas',[]))
print(','.join(schemas))
" 2>/dev/null || echo "unknown")
  echo "  Data API already enabled. Current db_schemas: ${CURRENT_SCHEMAS}"

  if [[ "${CURRENT_SCHEMAS}" != *"demo"* ]]; then
    echo "  'demo' not in db_schemas — patching..."
    PATCH1_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
      -X PATCH \
      -H "Authorization: Bearer ${WS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d '{"spec":{"db_schemas":["demo","public"]}}' \
      "https://${WORKSPACE_HOST}/api/2.0/postgres/${DATA_API_PATH}?update_mask=spec.db_schemas")
    if [[ "${PATCH1_STATUS}" =~ ^2 ]]; then
      echo "  Patched: db_schemas=[\"demo\",\"public\"] (HTTP ${PATCH1_STATUS}) ✓"
    else
      echo "  ERROR: PATCH db_schemas failed (HTTP ${PATCH1_STATUS})" >&2
      exit 1
    fi
  else
    echo "  'demo' already in db_schemas — no change needed."
  fi
else
  echo "  Data API not enabled (HTTP ${HTTP_STATUS}). Enabling now..."
  ENABLE_RESP=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Authorization: Bearer ${WS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"spec":{"db_schemas":["demo","public"]}}' \
    "https://${WORKSPACE_HOST}/api/2.0/postgres/${DATA_API_PATH}")
  ENABLE_STATUS=$(echo "${ENABLE_RESP}" | tail -n1)
  if [[ "${ENABLE_STATUS}" =~ ^20[012]$ ]]; then
    echo "  Data API enabled with db_schemas=[\"demo\",\"public\"] ✓"
  else
    echo "  ERROR: Failed to enable Data API (HTTP ${ENABLE_STATUS})" >&2
    echo "${ENABLE_RESP}" | sed '$d' >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Step 2: Set jwt_role_claim_key = ".sub"
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 2: Verify jwt_role_claim_key = \".sub\" ---"
CURRENT_KEY=$(curl -s \
  -H "Authorization: Bearer ${WS_TOKEN}" \
  "https://${WORKSPACE_HOST}/api/2.0/postgres/${DATA_API_PATH}" \
  | python3 -c "
import json,sys; d=json.load(sys.stdin)
r = d.get('response', d)
print(r.get('status',{}).get('jwt_role_claim_key','unknown'))
" 2>/dev/null || echo "unknown")

if [[ "${CURRENT_KEY}" == ".sub" ]]; then
  echo "  jwt_role_claim_key is already '.sub' — no change needed."
else
  echo "  Current jwt_role_claim_key: '${CURRENT_KEY}' — patching to '.sub'..."
  PATCH2_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PATCH \
    -H "Authorization: Bearer ${WS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"spec":{"jwt_role_claim_key":".sub"}}' \
    "https://${WORKSPACE_HOST}/api/2.0/postgres/${DATA_API_PATH}?update_mask=spec.jwt_role_claim_key")
  if [[ "${PATCH2_STATUS}" =~ ^2 ]]; then
    echo "  Patched: jwt_role_claim_key='.sub' (HTTP ${PATCH2_STATUS}) ✓"
  else
    echo "  ERROR: PATCH jwt_role_claim_key failed (HTTP ${PATCH2_STATUS})" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Step 3: databricks_auth — create SP role, grant to authenticator, grant demo CRUD
# ---------------------------------------------------------------------------
# Uses the databricks_create_role() SQL function from the databricks_auth extension.
# This creates the SP's Postgres role AND registers the Lakebase identity mapping
# (auth_method=LAKEBASE_OAUTH_V1, identity_type=SERVICE_PRINCIPAL) in one call,
# with the current user holding ADMIN OPTION so the subsequent GRANT to authenticator
# succeeds without superuser. This is the ONLY supported no-cloud_admin path.
echo ""
echo "--- Step 3: databricks_auth SP role setup ---"

SP_ALREADY_MEMBER=$(PGPASSWORD="${PG_TOKEN}" "${PSQL}" \
  "host=${PG_HOST} user=${PG_USER} dbname=databricks_postgres sslmode=require" \
  -t -c "
SELECT 1 FROM pg_auth_members am
JOIN pg_roles r ON r.oid=am.roleid
JOIN pg_roles m ON m.oid=am.member
WHERE r.rolname='${SP_CLIENT_ID}' AND m.rolname='authenticator';
" 2>/dev/null | tr -d ' ')

if [[ "${SP_ALREADY_MEMBER}" == "1" ]]; then
  echo "  authenticator is already a member of \"${SP_CLIENT_ID}\" ✓"
  echo "  Ensuring demo schema grants are current..."
  PGPASSWORD="${PG_TOKEN}" "${PSQL}" \
    "host=${PG_HOST} user=${PG_USER} dbname=databricks_postgres sslmode=require" \
    -c "
GRANT USAGE ON SCHEMA demo TO \"${SP_CLIENT_ID}\";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA demo TO \"${SP_CLIENT_ID}\";
GRANT USAGE ON ALL SEQUENCES IN SCHEMA demo TO \"${SP_CLIENT_ID}\";
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA demo TO \"${SP_CLIENT_ID}\";
" >/dev/null 2>&1
  echo "  demo schema grants applied ✓"
else
  echo "  Running databricks_create_role + authenticator grant + demo CRUD..."
  PGPASSWORD="${PG_TOKEN}" "${PSQL}" \
    "host=${PG_HOST} user=${PG_USER} dbname=databricks_postgres sslmode=require" \
    -v ON_ERROR_STOP=1 \
    -c "
CREATE EXTENSION IF NOT EXISTS databricks_auth;

SELECT databricks_create_role('${SP_CLIENT_ID}', 'SERVICE_PRINCIPAL');

GRANT \"${SP_CLIENT_ID}\" TO authenticator;

GRANT USAGE ON SCHEMA demo TO \"${SP_CLIENT_ID}\";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA demo TO \"${SP_CLIENT_ID}\";
GRANT USAGE ON ALL SEQUENCES IN SCHEMA demo TO \"${SP_CLIENT_ID}\";
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA demo TO \"${SP_CLIENT_ID}\";
" 2>&1
  echo "  SP role created, authenticator granted, demo CRUD applied ✓"
fi

echo ""
echo "=== Data API setup complete ==="
DATA_API_URL=$(curl -s -H "Authorization: Bearer ${WS_TOKEN}" \
  "https://${WORKSPACE_HOST}/api/2.0/postgres/${DATA_API_PATH}" \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('response',d)
print(r.get('status',{}).get('url','UNKNOWN'))
" 2>/dev/null)
echo "  Data API URL: ${DATA_API_URL}"
echo ""
echo "  Verify with:"
echo "    SP_TOKEN=\$(curl -s -u SP_CLIENT_ID:SP_SECRET https://WORKSPACE/oidc/v1/token -d grant_type=client_credentials&scope=all-apis | jq -r .access_token)"
echo "    curl -H \"Authorization: Bearer \$SP_TOKEN\" \"${DATA_API_URL}/demo/customers?limit=1\""
