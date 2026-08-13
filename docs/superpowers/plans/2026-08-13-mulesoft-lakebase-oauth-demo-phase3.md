# MuleSoft ↔ Lakebase OAuth Demo — Phase 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the *documented, reviewable* MuleSoft ↔ Lakebase OAuth integration pattern — a provisioned Lakebase project with schema/data, both auth chains proven working *outside* Mule via a smoke script, authored (not-yet-run) Mule apps for both connection styles, and the docs that explain them.

**Architecture:** One repo, two Mule apps over one `customers` table. App 1 (Data API) uses Mule's OAuth client-credentials module → Bearer token → PostgREST CRUD. App 2 (JDBC) uses the Database Connector with a scheduled refresh that mints a Lakebase database credential from an OAuth token. Phase 3 provisions the Lakebase side, proves both auth chains with a plain shell smoke script (de-risking before any Mule involvement), authors the Mule XML, and writes the deep-dive docs. It does **not** build/run the Mule apps — that is Phase 2, which assumes confirmed Mule tooling.

**Tech Stack:** Databricks CLI (`databricks postgres`), Lakebase Autoscaling Postgres, PostgREST Data API, `psql`/`curl`, Mule 4 (HTTP Connector + OAuth, Database Connector, Object Store, Scheduler), Maven.

**Spec:** `docs/superpowers/specs/2026-08-13-mulesoft-lakebase-oauth-demo-design.md`

## Global Constraints

- **Databricks profile is user-selected — never auto-select.** Every `databricks` command passes `--profile <PROFILE>` with the value the user chose in Task 1.
- **`sslmode=require`** on every Postgres connection (JDBC URL and psql).
- **No secrets committed.** SP client secret and any minted tokens live only in git-ignored `config-local.yaml` / `.env`. Committed docs and configs use placeholder shapes (`<workspace-host>`, `${databricks.client.secret}`).
- **Databricks CLI ≥ v0.294.0**, Postgres 16/17, `sslmode=require`.
- **Lakebase is Autoscaling-only** — use `databricks postgres` (never `databricks database`).
- **Phase 3 does not run Mule.** Mule apps are authored and validated for XML well-formedness only; full `mvn package`/run is Phase 2.
- **Demo table:** `customers(id serial pk, name text, email text unique, tier text, created_at timestamptz default now())`, in schema `demo` (dedicated schema, not `public`, for least-privilege).

---

### Task 1: Prerequisites & connection facts (HUMAN-GATED)

Gather the inputs the rest of the plan depends on. **This task requires user input and cannot be completed by an unattended subagent.**

**Files:**
- Create: `infra/connection-facts.md` (committed; **non-secret** facts only, using real values that are not sensitive + placeholders for anything sensitive)
- Create: `config-local.yaml` (git-ignored; holds SP client id/secret and any local-only values)

**Interfaces:**
- Produces: the canonical set of values every later task reads — `PROFILE`, `WORKSPACE_HOST`, `PROJECT_ID`, `BRANCH_ID`, `ENDPOINT_ID`, `ENDPOINT_PATH`, `PG_HOST`, `PG_DATABASE`, `SP_CLIENT_ID`, `SP_CLIENT_SECRET`, `DATA_API_URL`.

- [ ] **Step 1: Ask the user for the required inputs**

Ask, and wait for answers:
1. Which Databricks **profile** to use (list options: `databricks auth profiles`).
2. Whether to **reuse an existing Lakebase project** or **create a new one** (Task 2 branches on this).
3. Whether they already have an **M2M service principal** (OAuth client id + secret) for the demo, or need one created.

- [ ] **Step 2: Verify CLI + auth for the chosen profile**

Run:
```bash
databricks --version                      # expect >= v0.294.0
databricks postgres list-projects --profile <PROFILE> -o json
```
Expected: version OK; projects command returns JSON (proves auth works).

- [ ] **Step 3: If no service principal exists, create one and mint a secret**

Run (only if needed; requires account/workspace admin):
```bash
databricks service-principals create --display-name "mulesoft-lakebase-demo" --profile <PROFILE> -o json
# note the application_id → SP_CLIENT_ID
databricks service-principal-secrets create <SP_ID> --profile <PROFILE> -o json
# note the secret → SP_CLIENT_SECRET (shown once)
```
Store `SP_CLIENT_ID` and `SP_CLIENT_SECRET` in `config-local.yaml` (git-ignored).

- [ ] **Step 4: Write `config-local.yaml` (git-ignored) and `infra/connection-facts.md`**

`config-local.yaml`:
```yaml
databricks:
  profile: <PROFILE>
  host: <workspace-host>            # e.g. dbc-xxxx.cloud.databricks.com
  client_id: <SP_CLIENT_ID>
  client_secret: <SP_CLIENT_SECRET>
```
`infra/connection-facts.md` — a table of the non-secret facts (PROJECT_ID, BRANCH_ID, ENDPOINT_ID, PG_HOST, PG_DATABASE, DATA_API_URL, SP_CLIENT_ID) filled in as Tasks 2–4 discover them. Start it now with PROFILE + placeholders.

- [ ] **Step 5: Verify `config-local.yaml` is ignored**

Run: `git check-ignore config-local.yaml`
Expected: prints `config-local.yaml` (confirms it will not be committed).

- [ ] **Step 6: Commit**

```bash
git add infra/connection-facts.md
git commit -m "chore: capture Lakebase demo connection facts (non-secret)"
```

---

### Task 2: Provision or reuse the Lakebase project

**Files:**
- Modify: `infra/connection-facts.md` (fill in PROJECT_ID/BRANCH_ID/ENDPOINT_ID/PG_HOST/PG_DATABASE)
- Create: `infra/setup-lakebase.sh` (idempotent helper that discovers/creates the project and prints connection facts)

**Interfaces:**
- Consumes: `PROFILE`, reuse-or-create decision (Task 1).
- Produces: `PROJECT_ID`, `BRANCH_ID` (default `production`), `ENDPOINT_ID` (default `primary`), `ENDPOINT_PATH` = `projects/<PROJECT_ID>/branches/<BRANCH_ID>/endpoints/<ENDPOINT_ID>`, `PG_HOST`, `PG_DATABASE`.

- [ ] **Step 1: Discover commands (don't guess syntax)**

Run:
```bash
databricks postgres -h
databricks postgres create-project -h
databricks postgres get-endpoint -h
```

- [ ] **Step 2a (REUSE path): list and pick**

Run:
```bash
databricks postgres list-projects --profile <PROFILE> -o json
databricks postgres list-branches projects/<PROJECT_ID> --profile <PROFILE> -o json
databricks postgres list-databases projects/<PROJECT_ID>/branches/<BRANCH_ID> --profile <PROFILE> -o json
```
Confirm the chosen project/branch/database with the user.

- [ ] **Step 2b (CREATE path): create the project**

Run:
```bash
databricks postgres create-project mulesoft-lakebase-demo \
  --json '{"spec": {"display_name": "MuleSoft Lakebase Demo"}}' \
  --profile <PROFILE>
```
Auto-creates `production` branch + `primary` endpoint.

- [ ] **Step 3: Extract connection facts**

Run:
```bash
databricks postgres list-endpoints projects/<PROJECT_ID>/branches/production --profile <PROFILE> -o json
# → status.hosts.host = PG_HOST ; name = ENDPOINT_PATH
databricks postgres list-databases projects/<PROJECT_ID>/branches/production --profile <PROFILE> -o json
# → status.postgres_database = PG_DATABASE (often databricks_postgres)
```

- [ ] **Step 4: Write `infra/setup-lakebase.sh`**

A bash script that: reads `PROFILE`/`PROJECT_ID` from args or env, runs the list-* commands above, and prints a `KEY=value` block of all connection facts. Header `set -euo pipefail`. No secrets in output.

- [ ] **Step 5: Verify the script runs and prints facts**

Run: `bash infra/setup-lakebase.sh <PROJECT_ID> <PROFILE>`
Expected: prints PG_HOST, ENDPOINT_PATH, PG_DATABASE with real values.

- [ ] **Step 6: Update `infra/connection-facts.md` and commit**

```bash
git add infra/setup-lakebase.sh infra/connection-facts.md
git commit -m "feat(infra): provision/reuse Lakebase project + facts script"
```

---

### Task 3: Schema + seed data

**Files:**
- Create: `infra/schema.sql`
- Create: `infra/seed.sql`

**Interfaces:**
- Consumes: `PROJECT_ID`, `PROFILE`.
- Produces: schema `demo` with table `demo.customers` populated with sample rows.

- [ ] **Step 1: Write `infra/schema.sql`**

```sql
CREATE SCHEMA IF NOT EXISTS demo;

CREATE TABLE IF NOT EXISTS demo.customers (
    id         serial PRIMARY KEY,
    name       text NOT NULL,
    email      text NOT NULL UNIQUE,
    tier       text NOT NULL DEFAULT 'standard',
    created_at timestamptz NOT NULL DEFAULT now()
);
```

- [ ] **Step 2: Write `infra/seed.sql`**

```sql
INSERT INTO demo.customers (name, email, tier) VALUES
    ('Ada Lovelace',   'ada@example.com',   'gold'),
    ('Alan Turing',    'alan@example.com',  'standard'),
    ('Grace Hopper',   'grace@example.com', 'gold')
ON CONFLICT (email) DO NOTHING;
```

- [ ] **Step 3: Apply schema + seed**

Run:
```bash
databricks psql --project <PROJECT_ID> --profile <PROFILE> -- -f infra/schema.sql
databricks psql --project <PROJECT_ID> --profile <PROFILE> -- -f infra/seed.sql
```
(If `databricks psql` is unavailable, use the scriptable psql block from the databricks-lakebase skill: get-endpoint host + generate-database-credential token.)

- [ ] **Step 4: Verify rows exist**

Run:
```bash
databricks psql --project <PROJECT_ID> --profile <PROFILE> -- -c "SELECT count(*) FROM demo.customers;"
```
Expected: `3`.

- [ ] **Step 5: Commit**

```bash
git add infra/schema.sql infra/seed.sql
git commit -m "feat(infra): customers schema + seed data"
```

---

### Task 4: Service-principal Postgres role, grants & Data API enablement

**Files:**
- Create: `infra/grants.sql`
- Modify: `infra/connection-facts.md` (add `DATA_API_URL`, `SP_CLIENT_ID`)

**Interfaces:**
- Consumes: `SP_CLIENT_ID` (Task 1), `PROJECT_ID`, `PROFILE`.
- Produces: a Postgres role for the SP with CRUD on `demo.customers`; enabled Data API with `DATA_API_URL`.

- [ ] **Step 1: Write `infra/grants.sql`**

```sql
-- SP identity = its application/client id (M2M). Role name must match the identity.
CREATE ROLE "<SP_CLIENT_ID>" LOGIN;
GRANT USAGE ON SCHEMA demo TO "<SP_CLIENT_ID>";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA demo TO "<SP_CLIENT_ID>";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA demo TO "<SP_CLIENT_ID>";
ALTER DEFAULT PRIVILEGES IN SCHEMA demo
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "<SP_CLIENT_ID>";
```
(Replace `<SP_CLIENT_ID>` with the real value before applying; the committed file keeps the placeholder.)

- [ ] **Step 2: Apply grants**

Run:
```bash
SP_ID=$(python3 -c "import yaml;print(yaml.safe_load(open('config-local.yaml'))['databricks']['client_id'])")
databricks psql --project <PROJECT_ID> --profile <PROFILE> -- \
  -c "$(sed "s/<SP_CLIENT_ID>/$SP_ID/g" infra/grants.sql)"
```

- [ ] **Step 3: Enable the Data API (UI — documented action)**

The Data API is enabled in the Lakebase project UI (Data API → Enable). Record the steps and the resulting `DATA_API_URL` in `infra/connection-facts.md`. Ensure the `demo` schema is in the exposed-schemas list (default exposes `public`; add `demo`).

- [ ] **Step 4: Verify role + grants**

Run:
```bash
databricks psql --project <PROJECT_ID> --profile <PROFILE> -- \
  -c "\dp demo.customers"
```
Expected: the SP role appears with `arwd` (select/insert/update/delete) privileges.

- [ ] **Step 5: Commit**

```bash
git add infra/grants.sql infra/connection-facts.md
git commit -m "feat(infra): SP Postgres role + grants; document Data API enablement"
```

---

### Task 5: Auth-chain smoke script (proves BOTH chains outside Mule)

This is the Phase-3 de-risk: prove the OAuth chains work with plain shell before authoring any Mule.

**Files:**
- Create: `infra/smoke-test.sh`

**Interfaces:**
- Consumes: everything in `config-local.yaml` + connection facts.
- Produces: exit 0 with two ✓ lines (JDBC chain, Data API chain).

- [ ] **Step 1: Write `infra/smoke-test.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
PROFILE=<PROFILE>; PROJECT=<PROJECT_ID>
EP=projects/$PROJECT/branches/production/endpoints/primary

# --- Chain 1: JDBC/psql path — OAuth token as Postgres password ---
HOST=$(databricks postgres get-endpoint "$EP" --profile "$PROFILE" -o json \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['status']['hosts']['host'])")
TOKEN=$(databricks postgres generate-database-credential "$EP" --profile "$PROFILE" -o json \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['token'])")
USER=$(databricks current-user me --profile "$PROFILE" -o json | python3 -c "import json,sys;print(json.load(sys.stdin)['userName'])")
PGPASSWORD="$TOKEN" psql "host=$HOST user=$USER dbname=databricks_postgres sslmode=require" \
  -c "SELECT count(*) FROM demo.customers;" >/dev/null && echo "✓ JDBC/psql auth chain OK"

# --- Chain 2: Data API path — OAuth client-credentials Bearer token ---
CID=$(python3 -c "import yaml;print(yaml.safe_load(open('config-local.yaml'))['databricks']['client_id'])")
CSEC=$(python3 -c "import yaml;print(yaml.safe_load(open('config-local.yaml'))['databricks']['client_secret'])")
WHOST=$(python3 -c "import yaml;print(yaml.safe_load(open('config-local.yaml'))['databricks']['host'])")
BEARER=$(curl -s --request POST "https://$WHOST/oidc/v1/token" \
  --data "grant_type=client_credentials&scope=all-apis" \
  -u "$CID:$CSEC" | python3 -c "import json,sys;print(json.load(sys.stdin)['access_token'])")
curl -sf -H "Authorization: Bearer $BEARER" "<DATA_API_URL>/demo/customers?limit=1" >/dev/null \
  && echo "✓ Data API auth chain OK"
```

- [ ] **Step 2: Run the smoke test**

Run: `bash infra/smoke-test.sh`
Expected: two lines — `✓ JDBC/psql auth chain OK` and `✓ Data API auth chain OK`.

- [ ] **Step 3: If either chain fails, stop and diagnose**

Use superpowers:systematic-debugging. Common causes: `demo` schema not exposed in Data API; SP role missing; token scope wrong. **Do not proceed to Mule authoring until both chains pass** — this is the feasibility gate.

- [ ] **Step 4: Commit**

```bash
git add infra/smoke-test.sh
git commit -m "test(infra): smoke script proves both OAuth chains outside Mule"
```

---

### Task 6: Author the Data API Mule app (App 1)

Author only — Phase 3 validates XML well-formedness; build/run is Phase 2.

**Files:**
- Create: `mule-data-api/pom.xml`
- Create: `mule-data-api/src/main/mule/data-api.xml`
- Create: `mule-data-api/src/main/resources/config.yaml` (placeholders; real via secure props in later phases)
- Create: `mule-data-api/src/main/resources/config-local.example.yaml`

**Interfaces:**
- Consumes: `DATA_API_URL`, `WORKSPACE_HOST`, `SP_CLIENT_ID/SECRET` (via properties).
- Produces: five flows — `list-customers`, `get-customer`, `create-customer`, `update-customer`, `delete-customer` — over `/customers`.

- [ ] **Step 1: Write `pom.xml`**

A standard Mule 4 application pom (packaging `mule-application`, mule-maven-plugin, HTTP connector, OAuth support bundled with HTTP connector). Use the current Mule runtime 4.x and HTTP connector 1.x coordinates. Mark with a comment: *connector versions to be reconciled at first `mvn package` in Phase 2.*

- [ ] **Step 2: Write `data-api.xml` — configs**

```xml
<http:listener-config name="HTTP_Listener">
    <http:listener-connection host="0.0.0.0" port="8081"/>
</http:listener-config>

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
(`oauth` = `http://www.mulesoft.org/schema/mule/oauth`. `dataapi.basePath` = `/demo` — the exposed schema.)

- [ ] **Step 3: Write `data-api.xml` — the five CRUD flows**

```xml
<flow name="list-customers">
    <http:listener config-ref="HTTP_Listener" path="/customers" allowedMethods="GET"/>
    <http:request config-ref="DataApi_HTTP" method="GET" path="/customers">
        <http:query-params>#[{ 'order': 'id' }]</http:query-params>
    </http:request>
</flow>

<flow name="get-customer">
    <http:listener config-ref="HTTP_Listener" path="/customers/{id}" allowedMethods="GET"/>
    <http:request config-ref="DataApi_HTTP" method="GET" path="/customers">
        <http:query-params>#[{ 'id': 'eq.' ++ attributes.uriParams.id }]</http:query-params>
    </http:request>
</flow>

<flow name="create-customer">
    <http:listener config-ref="HTTP_Listener" path="/customers" allowedMethods="POST"/>
    <http:request config-ref="DataApi_HTTP" method="POST" path="/customers">
        <http:headers>#[{ 'Prefer': 'return=representation', 'Content-Type': 'application/json' }]</http:headers>
    </http:request>
</flow>

<flow name="update-customer">
    <http:listener config-ref="HTTP_Listener" path="/customers/{id}" allowedMethods="PATCH"/>
    <http:request config-ref="DataApi_HTTP" method="PATCH" path="/customers">
        <http:query-params>#[{ 'id': 'eq.' ++ attributes.uriParams.id }]</http:query-params>
        <http:headers>#[{ 'Prefer': 'return=representation', 'Content-Type': 'application/json' }]</http:headers>
    </http:request>
</flow>

<flow name="delete-customer">
    <http:listener config-ref="HTTP_Listener" path="/customers/{id}" allowedMethods="DELETE"/>
    <http:request config-ref="DataApi_HTTP" method="DELETE" path="/customers">
        <http:query-params>#[{ 'id': 'eq.' ++ attributes.uriParams.id }]</http:query-params>
    </http:request>
</flow>
```

- [ ] **Step 4: Write `config.yaml` + `config-local.example.yaml`**

`config.yaml` (committed, placeholders):
```yaml
dataapi:
  host: "<data-api-host>"
  basePath: "/demo"
databricks:
  host: "<workspace-host>"
  client:
    id: "<SP_CLIENT_ID>"
    secret: "${secure::databricks.client.secret}"
```
`config-local.example.yaml`: same keys with a comment to copy → `config-local.yaml` (git-ignored) and fill real values for Phase 2.

- [ ] **Step 5: Validate XML well-formedness**

Run: `xmllint --noout mule-data-api/src/main/mule/data-api.xml`
Expected: no output (well-formed). Also confirm all `${...}` placeholders have a matching key in `config.yaml`.

- [ ] **Step 6: Commit**

```bash
git add mule-data-api/
git commit -m "feat(mule): Data API app — OAuth client-credentials CRUD flows (authored)"
```

---

### Task 7: Author the JDBC Mule app (App 2)

Author only. The **token-injection mechanism is the Phase-2 spike** (spec §5); Phase 3 authors the documented structure with the refresh flow and DB config, and clearly annotates the spike point.

**Files:**
- Create: `mule-jdbc/pom.xml`
- Create: `mule-jdbc/src/main/mule/jdbc.xml`
- Create: `mule-jdbc/src/main/resources/config.yaml`
- Create: `mule-jdbc/src/main/resources/config-local.example.yaml`

**Interfaces:**
- Consumes: `PG_HOST`, `PG_DATABASE`, `SP_CLIENT_ID/SECRET`, `ENDPOINT_PATH`, `WORKSPACE_HOST`.
- Produces: a scheduled `refresh-lakebase-token` flow + five CRUD flows over `demo.customers`.

- [ ] **Step 1: Write `pom.xml`**

Mule 4 application pom with Database Connector, Object Store connector, HTTP connector. PostgreSQL JDBC driver as a dependency. Comment: *connector/driver versions reconciled at first `mvn package` in Phase 2.*

- [ ] **Step 2: Write `jdbc.xml` — DB config + Object Store (spike point annotated)**

```xml
<os:object-store name="TokenStore" persistent="false"/>

<!-- SPIKE (Phase 2): Mule's DB global config does not re-read a static
     placeholder at runtime. Resolve which technique rotates the password:
     (a) OS-backed credential + reconnection strategy,
     (b) custom HikariCP DataSource bean w/ credential supplier,
     (c) per-request dynamic DB config.
     Authored here with a placeholder password for structure/review. -->
<db:config name="Lakebase_DB">
    <db:generic-connection
        url="jdbc:postgresql://${pg.host}:5432/${pg.database}?sslmode=require"
        driverClassName="org.postgresql.Driver"
        user="${pg.user}"
        password="#[vars.lakebaseToken default p('pg.bootstrap.token')]"/>
</db:config>
```

- [ ] **Step 3: Write `jdbc.xml` — scheduled refresh flow**

```xml
<flow name="refresh-lakebase-token">
    <scheduler>
        <scheduling-strategy>
            <fixed-frequency frequency="2700" timeUnit="SECONDS"/>  <!-- 45 min -->
        </scheduling-strategy>
    </scheduler>
    <!-- 1. Obtain Databricks OAuth token (client-credentials against
            https://${databricks.host}/oidc/v1/token, scope all-apis).
            Reuse an HTTP request-config with oauth:client-credentials-grant-type. -->
    <!-- 2. Mint the Lakebase database credential for ${lakebase.endpointPath}.
            REST equivalent of `databricks postgres generate-database-credential <endpoint>`;
            exact REST path to be confirmed in Phase 2 spike. -->
    <os:store objectStore="TokenStore" key="lakebase-pg-token">
        <os:value>#[payload.token]</os:value>
    </os:store>
    <logger level="INFO" message="Refreshed Lakebase DB credential"/>
</flow>
```

- [ ] **Step 4: Write `jdbc.xml` — five CRUD flows**

```xml
<flow name="list-customers">
    <http:listener config-ref="HTTP_Listener" path="/customers" allowedMethods="GET"/>
    <db:select config-ref="Lakebase_DB">
        <db:sql>SELECT id, name, email, tier, created_at FROM demo.customers ORDER BY id</db:sql>
    </db:select>
</flow>

<flow name="get-customer">
    <http:listener config-ref="HTTP_Listener" path="/customers/{id}" allowedMethods="GET"/>
    <db:select config-ref="Lakebase_DB">
        <db:sql>SELECT id, name, email, tier, created_at FROM demo.customers WHERE id = :id</db:sql>
        <db:input-parameters>#[{ 'id': attributes.uriParams.id }]</db:input-parameters>
    </db:select>
</flow>

<flow name="create-customer">
    <http:listener config-ref="HTTP_Listener" path="/customers" allowedMethods="POST"/>
    <db:insert config-ref="Lakebase_DB">
        <db:sql>INSERT INTO demo.customers (name, email, tier) VALUES (:name, :email, :tier) RETURNING *</db:sql>
        <db:input-parameters>#[{ 'name': payload.name, 'email': payload.email, 'tier': payload.tier default 'standard' }]</db:input-parameters>
    </db:insert>
</flow>

<flow name="update-customer">
    <http:listener config-ref="HTTP_Listener" path="/customers/{id}" allowedMethods="PATCH"/>
    <db:update config-ref="Lakebase_DB">
        <db:sql>UPDATE demo.customers SET tier = :tier WHERE id = :id RETURNING *</db:sql>
        <db:input-parameters>#[{ 'id': attributes.uriParams.id, 'tier': payload.tier }]</db:input-parameters>
    </db:update>
</flow>

<flow name="delete-customer">
    <http:listener config-ref="HTTP_Listener" path="/customers/{id}" allowedMethods="DELETE"/>
    <db:delete config-ref="Lakebase_DB">
        <db:sql>DELETE FROM demo.customers WHERE id = :id</db:sql>
        <db:input-parameters>#[{ 'id': attributes.uriParams.id }]</db:input-parameters>
    </db:delete>
</flow>
```
(Also declare `HTTP_Listener` config as in Task 6 Step 2.)

- [ ] **Step 5: Write `config.yaml` + `config-local.example.yaml`**

```yaml
pg:
  host: "<PG_HOST>"
  database: "databricks_postgres"
  user: "<SP_CLIENT_ID>"
lakebase:
  endpointPath: "projects/<PROJECT_ID>/branches/production/endpoints/primary"
databricks:
  host: "<workspace-host>"
  client:
    id: "<SP_CLIENT_ID>"
    secret: "${secure::databricks.client.secret}"
```

- [ ] **Step 6: Validate XML well-formedness**

Run: `xmllint --noout mule-jdbc/src/main/mule/jdbc.xml`
Expected: no output. Confirm every `${...}`/`p('...')` placeholder has a `config.yaml` key.

- [ ] **Step 7: Commit**

```bash
git add mule-jdbc/
git commit -m "feat(mule): JDBC app — DB CRUD + scheduled token refresh (authored; injection = Phase 2 spike)"
```

---

### Task 8: Documentation deep-dives + README

**Files:**
- Create: `docs/architecture.md`, `docs/data-api-oauth.md`, `docs/jdbc-token-refresh.md`
- Create: `README.md`

**Interfaces:**
- Consumes: everything above.
- Produces: the Phase-3 deliverable — a reviewer can understand both OAuth chains end to end.

- [ ] **Step 1: Write `docs/architecture.md`**

Two Mermaid sequence diagrams (one per auth chain, matching spec §3.3), the CRUD-mapping table (spec §3.4), and a short "why two apps" paragraph.

- [ ] **Step 2: Write `docs/data-api-oauth.md`**

Deep-dive on the clean path: how Mule's OAuth client-credentials module acquires/refreshes the Bearer token, the PostgREST verb mapping, the SP-role requirement, and the exact `curl` equivalents (from the smoke script) a reader can run.

- [ ] **Step 3: Write `docs/jdbc-token-refresh.md`**

Deep-dive on the fiddly path: why the JDBC password expires, the scheduled-refresh design, the three candidate injection techniques (spec §5) flagged as the Phase-2 spike, and the native-password contrast ("easy but not OAuth").

- [ ] **Step 4: Write `README.md`**

Overview, the OAuth story in 3 sentences, repo map, and "how to run each phase" — Phase 3 = run `infra/smoke-test.sh`; Phases 2/1 = forthcoming plans. Link the spec and this plan.

- [ ] **Step 5: Verify docs render + links resolve**

Run: `ls docs/*.md README.md` and eyeball Mermaid fences are closed. Confirm internal links (spec, plan) point to real paths.

- [ ] **Step 6: Commit**

```bash
git add docs/architecture.md docs/data-api-oauth.md docs/jdbc-token-refresh.md README.md
git commit -m "docs: architecture + both OAuth deep-dives + README"
```

---

## Self-Review

**1. Spec coverage:**
- Spec §2 Data API auth → Tasks 4, 5, 6. ✓
- Spec §2 JDBC auth → Tasks 5, 7. ✓
- Spec §3.1 repo layout → Tasks 1–8 create every listed path. ✓
- Spec §3.2 customers domain → Task 3. ✓
- Spec §3.3 auth chains → Tasks 6, 7, 8 (docs). ✓
- Spec §3.4 CRUD surface → Tasks 6, 7 (both apps, all five ops). ✓
- Spec §4 Phase 3 deliverables → whole plan; Phases 2/1 explicitly deferred to their own plans. ✓
- Spec §5 JDBC spike → Task 7 annotated as spike; resolution deferred to Phase 2 (correct — spec places it in Phase 2). ✓
- Spec §6 error handling → *partially deferred*: Phase 3 authors flows without full error mapping; error handling is exercised when apps run in Phase 2. Noted, not a gap for Phase 3.
- Spec §7 smoke script + curl matrix → Task 5 (smoke); MUnit/curl matrix is Phase 2 (apps not run in Phase 3). ✓
- Spec §8 security → Global Constraints + Task 1 (git-ignore) + Task 4 (least-privilege `demo` schema). ✓
- Spec §9 out-of-scope → honored (no APIkit, no toggle). ✓

**2. Placeholder scan:** All `<...>` tokens are *data values the user supplies* (profile, IDs, secrets), not un-specified logic — each has an explicit source task. No "TODO/implement later" for logic except the two items the spec deliberately designates as the Phase-2 spike (JDBC injection mechanism, exact generate-credential REST path), which are correctly out of Phase 3's scope.

**3. Type consistency:** Flow names, config names (`HTTP_Listener`, `DataApi_HTTP`, `Lakebase_DB`, `TokenStore`), property keys (`dataapi.host`, `pg.host`, `databricks.client.id`), and the `demo.customers` columns are consistent across Tasks 3, 6, 7, 8. ✓
