#!/usr/bin/env bash
# data-api-setup.sh — Reproducible Data API setup for the mulesoft-lakebase-demo project.
#
# Performs all four required steps to enable the Lakebase PostgREST Data API
# with SP OAuth M2M (client-credentials) authentication:
#
#   Step 1: Enable the Data API (POST) with db_schemas including "demo".
#   Step 2: Verify/set jwt_role_claim_key = ".sub" (SP tokens carry client_id in .sub).
#   Step 3: Create (or re-create) the Lakebase role with LAKEBASE_OAUTH_V1 auth_method.
#   Step 4: Attempt GRANT "<SP_CLIENT_ID>" TO authenticator (requires superuser ADMIN OPTION —
#           expected to fail for project-creator accounts; documented as a Lakebase product gap).
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
#   - curl, python3
#   - The Lakebase project and production branch must already exist
#   - infra/grants.sql must have been applied (schema + SP Postgres role grants)
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
ROLE_ID="sp-mulesoft-demo"

# Resolve workspace host from CLI profile if not provided
if [[ -z "${WORKSPACE_HOST}" ]]; then
  WORKSPACE_HOST=$(databricks auth describe --profile "${PROFILE}" -o json 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('details',{}).get('host','').lstrip('https://'))" 2>/dev/null || true)
fi

if [[ -z "${WORKSPACE_HOST}" ]]; then
  # Fall back: extract from databrickscfg
  WORKSPACE_HOST=$(python3 -c "
import configparser, os, sys
cfg = configparser.ConfigParser()
cfg.read(os.path.expanduser('~/.databrickscfg'))
host = cfg.get('${PROFILE}', 'host', fallback='')
print(host.lstrip('https://').rstrip('/'))
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
# Step 3: Create (or verify) the SP Lakebase role with LAKEBASE_OAUTH_V1
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 3: Ensure SP Lakebase role (LAKEBASE_OAUTH_V1) ---"
EXISTING_ROLE=$(databricks postgres get-role "${BRANCH_PATH}/roles/${ROLE_ID}" \
  --profile "${PROFILE}" -o json 2>&1)

if echo "${EXISTING_ROLE}" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('status',{}).get('auth_method')=='LAKEBASE_OAUTH_V1' else 1)" 2>/dev/null; then
  echo "  SP Lakebase role '${ROLE_ID}' already exists with LAKEBASE_OAUTH_V1 ✓"
elif echo "${EXISTING_ROLE}" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if 'role_id' in d.get('status',{}) else 1)" 2>/dev/null; then
  echo "  SP Lakebase role '${ROLE_ID}' exists but has wrong auth_method — deleting and re-creating..."
  databricks postgres delete-role "${BRANCH_PATH}/roles/${ROLE_ID}" --profile "${PROFILE}" >/dev/null 2>&1
  databricks postgres create-role "${BRANCH_PATH}" \
    --role-id "${ROLE_ID}" \
    --json "{\"spec\":{\"identity_type\":\"SERVICE_PRINCIPAL\",\"postgres_role\":\"${SP_CLIENT_ID}\",\"auth_method\":\"LAKEBASE_OAUTH_V1\"}}" \
    --profile "${PROFILE}" -o json >/dev/null
  echo "  Created SP Lakebase role '${ROLE_ID}' with LAKEBASE_OAUTH_V1 ✓"
else
  # Check if there's another role for this SP_CLIENT_ID with the wrong type
  OTHER_ROLE=$(databricks postgres list-roles "${BRANCH_PATH}" --profile "${PROFILE}" -o json 2>/dev/null \
    | python3 -c "
import json,sys
roles=json.load(sys.stdin)
for r in roles:
    if r.get('status',{}).get('postgres_role')=='${SP_CLIENT_ID}':
        print(r['name'])
        break
" 2>/dev/null || true)
  if [[ -n "${OTHER_ROLE}" ]]; then
    echo "  Found conflicting role '${OTHER_ROLE}' for SP — deleting..."
    databricks postgres delete-role "${OTHER_ROLE}" --profile "${PROFILE}" >/dev/null 2>&1
  fi
  databricks postgres create-role "${BRANCH_PATH}" \
    --role-id "${ROLE_ID}" \
    --json "{\"spec\":{\"identity_type\":\"SERVICE_PRINCIPAL\",\"postgres_role\":\"${SP_CLIENT_ID}\",\"auth_method\":\"LAKEBASE_OAUTH_V1\"}}" \
    --profile "${PROFILE}" -o json >/dev/null
  echo "  Created SP Lakebase role '${ROLE_ID}' with LAKEBASE_OAUTH_V1 ✓"
fi

# ---------------------------------------------------------------------------
# Step 4: GRANT SP role to authenticator (requires superuser ADMIN OPTION)
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 4: GRANT \"${SP_CLIENT_ID}\" TO authenticator ---"
echo "  NOTE: This step requires a Postgres superuser (cloud_admin) or ADMIN OPTION."
echo "  Project-creator accounts (like the workspace owner) do NOT have ADMIN OPTION"
echo "  on the SP Postgres role, even if they have CREATEROLE. This is a known"
echo "  Lakebase product gap — create-role does not auto-grant SP roles to authenticator."
echo ""

EP_PATH="${BRANCH_PATH}/endpoints/primary"
PG_TOKEN=$(databricks postgres generate-database-credential "${EP_PATH}" \
  --profile "${PROFILE}" -o json \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['token'])")
PG_HOST=$(databricks postgres get-endpoint "${EP_PATH}" --profile "${PROFILE}" -o json \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['status']['hosts']['host'])")
PG_USER=$(databricks current-user me --profile "${PROFILE}" -o json \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['userName'])")
PSQL="${PSQL:-psql}"

echo "  Attempting: GRANT \"${SP_CLIENT_ID}\" TO authenticator;"
GRANT_EXIT=0
GRANT_RESULT=$(PGPASSWORD="${PG_TOKEN}" "${PSQL}" \
  "host=${PG_HOST} user=${PG_USER} dbname=databricks_postgres sslmode=require" \
  -c "GRANT \"${SP_CLIENT_ID}\" TO authenticator;" 2>&1) || GRANT_EXIT=$?
echo "  Result: ${GRANT_RESULT}"

if [[ ${GRANT_EXIT} -eq 0 ]]; then
  echo "  GRANT succeeded ✓ — Data API chain should now work."
else
  echo ""
  echo "  GRANT FAILED (expected — Lakebase product gap)."
  echo "  To unblock, a workspace admin must run as cloud_admin:"
  echo "    GRANT \"${SP_CLIENT_ID}\" TO authenticator;"
  echo "  Or open a Databricks support ticket to wire up the authenticator membership."
  echo ""
  echo "  The JDBC chain (psql direct) is unaffected and will continue to work."
fi

echo ""
echo "=== Data API setup complete ==="
echo "  Data API URL: https://${PG_HOST}/api/2.0/workspace/$(
  curl -s -H "Authorization: Bearer ${WS_TOKEN}" \
    "https://${WORKSPACE_HOST}/api/2.0/postgres/${DATA_API_PATH}" \
    | python3 -c "
import json,sys,re
d=json.load(sys.stdin)
r=d.get('response',d)
url=r.get('status',{}).get('url','')
m=re.search(r'/workspace/(\d+)/', url)
print(m.group(1) if m else 'UNKNOWN')
" 2>/dev/null)/rest/databricks_postgres"
