#!/usr/bin/env bash
set -euo pipefail

PROFILE=mulesoft-lakebase-demo
PROJECT=mulesoft-lakebase-demo
EP=projects/$PROJECT/branches/production/endpoints/primary
DATA_API_URL=https://<PG_HOST>/api/2.0/workspace/<WORKSPACE_ID>/rest/databricks_postgres
PSQL=/opt/homebrew/Cellar/postgresql@17/17.9/bin/psql

# --- JDBC / Postgres-wire OAuth chain ---
# (smoke-test runs JDBC first for convenience; the docs number Data API as Chain 1)
HOST=$(databricks postgres get-endpoint "$EP" --profile "$PROFILE" -o json \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['status']['hosts']['host'])")
TOKEN=$(databricks postgres generate-database-credential "$EP" --profile "$PROFILE" -o json \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['token'])")
USER=$(databricks current-user me --profile "$PROFILE" -o json \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['userName'])")
PGPASSWORD="$TOKEN" "$PSQL" "host=$HOST user=$USER dbname=databricks_postgres sslmode=require" \
  -c "SELECT count(*) FROM demo.customers;" >/dev/null && echo "✓ JDBC/psql auth chain OK"

# --- Data API (PostgREST) OAuth chain ---
CID=$(python3 -c "import yaml;print(yaml.safe_load(open('config-local.yaml'))['databricks']['client_id'])")
CSEC=$(python3 -c "import yaml;print(yaml.safe_load(open('config-local.yaml'))['databricks']['client_secret'])")
WHOST=$(python3 -c "import yaml;print(yaml.safe_load(open('config-local.yaml'))['databricks']['host'])")
BEARER=$(curl -s --request POST "https://$WHOST/oidc/v1/token" \
  --data "grant_type=client_credentials&scope=all-apis" \
  -u "$CID:$CSEC" | python3 -c "import json,sys;print(json.load(sys.stdin)['access_token'])")
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $BEARER" \
  "${DATA_API_URL}/demo/customers?limit=1")
if [ "$STATUS" = "200" ]; then
  echo "✓ Data API auth chain OK"
else
  echo "✗ Data API auth chain FAILED (HTTP $STATUS)" >&2
  # Try alternate path forms for diagnosis
  echo "  Trying without schema prefix..." >&2
  STATUS2=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $BEARER" \
    "${DATA_API_URL}/customers?limit=1")
  echo "  ${DATA_API_URL}/customers?limit=1 → HTTP $STATUS2" >&2
  STATUS3=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $BEARER" \
    -H "Accept-Profile: demo" \
    "${DATA_API_URL}/customers?limit=1")
  echo "  ${DATA_API_URL}/customers?limit=1 + Accept-Profile: demo → HTTP $STATUS3" >&2
  # Print response body for the original path (without exposing token)
  BODY=$(curl -s -H "Authorization: Bearer $BEARER" \
    "${DATA_API_URL}/demo/customers?limit=1" 2>&1 | head -c 500)
  echo "  Response body (truncated): $BODY" >&2
  exit 1
fi
