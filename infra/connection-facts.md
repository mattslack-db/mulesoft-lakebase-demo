# MuleSoft ↔ Lakebase Demo — Connection Facts

Non-secret connection values for the demo environment.
**Do not add secrets to this file.** Credentials live in `config-local.yaml` (git-ignored).

## Workspace

| Key | Value |
|-----|-------|
| `PROFILE` | `fe-sandbox-wordpress` |
| `WORKSPACE_HOST` | `fe-sandbox-wordpress-connector-test.cloud.databricks.com` |

## Service Principal (OAuth M2M)

| Key | Value |
|-----|-------|
| `SP_DISPLAY_NAME` | `mulesoft-lakebase-demo` |
| `SP_CLIENT_ID` | `3a20b4bd-f64a-4288-a8d1-6ea26c554305` |

> `SP_CLIENT_SECRET` — stored only in `config-local.yaml`, never here.

## Lakebase Project (filled in Task 2)

| Key | Value |
|-----|-------|
| `PROJECT_ID` | `mulesoft-lakebase-demo` |
| `BRANCH_ID` | `production` |

## Lakebase Endpoint (filled in Task 2)

| Key | Value |
|-----|-------|
| `ENDPOINT_ID` | `primary` |
| `ENDPOINT_PATH` | `projects/mulesoft-lakebase-demo/branches/production/endpoints/primary` |
| `PG_HOST` | `ep-rough-hill-d1qt6anl.database.us-west-2.cloud.databricks.com` |
| `PG_DATABASE` | `databricks_postgres` |

## Data API (filled in Task 4)

| Key | Value |
|-----|-------|
| `DATA_API_URL` | `<to-be-filled-in-Task-4>` |
