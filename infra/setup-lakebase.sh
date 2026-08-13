#!/usr/bin/env bash
# setup-lakebase.sh — Discover connection facts for an existing Lakebase project.
#
# Usage:
#   bash infra/setup-lakebase.sh <PROJECT_ID> <PROFILE>
#   PROJECT_ID=mulesoft-lakebase-demo PROFILE=fe-sandbox-wordpress bash infra/setup-lakebase.sh
#
# Outputs a KEY=value block with all connection facts (no secrets).

set -euo pipefail

# ---------------------------------------------------------------------------
# Arguments / env
# ---------------------------------------------------------------------------
PROJECT_ID="${1:-${PROJECT_ID:-}}"
PROFILE="${2:-${PROFILE:-}}"

if [[ -z "${PROJECT_ID}" ]]; then
  echo "ERROR: PROJECT_ID is required (arg 1 or env var)" >&2
  exit 1
fi
if [[ -z "${PROFILE}" ]]; then
  echo "ERROR: PROFILE is required (arg 2 or env var)" >&2
  exit 1
fi

BRANCH_ID="production"

# ---------------------------------------------------------------------------
# Discover endpoint facts
# ---------------------------------------------------------------------------
ENDPOINT_JSON=$(databricks postgres list-endpoints \
  "projects/${PROJECT_ID}/branches/${BRANCH_ID}" \
  --profile "${PROFILE}" \
  -o json 2>/dev/null)

ENDPOINT_PATH=$(python3 -c "
import json, sys
items = json.loads(sys.stdin.read())
if not items:
    print('ERROR: no endpoints found', file=sys.stderr)
    sys.exit(1)
# prefer the primary endpoint; fall back to first
primary = next((e for e in items if e.get('endpoint_id') == 'primary'), items[0])
print(primary['name'])
" <<< "${ENDPOINT_JSON}")

ENDPOINT_ID=$(python3 -c "
import json, sys
items = json.loads(sys.stdin.read())
primary = next((e for e in items if e.get('endpoint_id') == 'primary'), items[0])
print(primary['endpoint_id'])
" <<< "${ENDPOINT_JSON}")

PG_HOST=$(python3 -c "
import json, sys
items = json.loads(sys.stdin.read())
primary = next((e for e in items if e.get('endpoint_id') == 'primary'), items[0])
print(primary['status']['hosts']['host'])
" <<< "${ENDPOINT_JSON}")

# ---------------------------------------------------------------------------
# Discover database facts
# ---------------------------------------------------------------------------
DB_JSON=$(databricks postgres list-databases \
  "projects/${PROJECT_ID}/branches/${BRANCH_ID}" \
  --profile "${PROFILE}" \
  -o json 2>/dev/null)

PG_DATABASE=$(python3 -c "
import json, sys
items = json.loads(sys.stdin.read())
if not items:
    print('ERROR: no databases found', file=sys.stderr)
    sys.exit(1)
print(items[0]['status']['postgres_database'])
" <<< "${DB_JSON}")

# ---------------------------------------------------------------------------
# Print connection facts block
# ---------------------------------------------------------------------------
cat <<EOF
PROJECT_ID=${PROJECT_ID}
BRANCH_ID=${BRANCH_ID}
ENDPOINT_ID=${ENDPOINT_ID}
ENDPOINT_PATH=${ENDPOINT_PATH}
PG_HOST=${PG_HOST}
PG_DATABASE=${PG_DATABASE}
EOF
