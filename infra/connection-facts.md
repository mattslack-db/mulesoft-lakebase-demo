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
| `PROJECT_ID` | `<to-be-filled-in-Task-2>` |
| `BRANCH_ID` | `<to-be-filled-in-Task-2>` |

## Lakebase Endpoint (filled in Task 2)

| Key | Value |
|-----|-------|
| `ENDPOINT_ID` | `<to-be-filled-in-Task-2>` |
| `ENDPOINT_PATH` | `<to-be-filled-in-Task-2>` |
| `PG_HOST` | `<to-be-filled-in-Task-2>` |
| `PG_DATABASE` | `<to-be-filled-in-Task-2>` |

## Data API (filled in Task 4)

| Key | Value |
|-----|-------|
| `DATA_API_URL` | `<to-be-filled-in-Task-4>` |
