# MuleSoft ↔ Lakebase OAuth Demo — Phase 2 Implementation Plan (local run via Mule Kernel CE + Docker)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (or superpowers:executing-plans) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make the two authored Mule apps actually **build and run locally** against the live Lakebase workspace, using the **free Mule Kernel (Community Edition) runtime in Docker** (no Anypoint Studio, no Anypoint account, no EE license), and exercise full CRUD on `demo.customers` over both OAuth chains.

**Architecture:** Build each app to a `.jar` with the Mule Maven plugin, bake it into a Docker image based on a public **Mule Kernel CE** base image, run it, and drive CRUD with `curl`. Replace the EE-only `secure-configuration-property-module` with plain `<configuration-properties>` + secret via environment variable. The JDBC app's token-injection mechanism and credential-mint REST call are resolved here (the Phase-3-deferred spike).

**Tech Stack:** Mule Kernel 4.x (CE) Docker image, Mule Maven plugin, Maven, Docker, `curl`, Databricks OAuth (`/oidc/v1/token`) + Lakebase `generate-database-credential`.

**Spec:** `docs/superpowers/specs/2026-08-13-mulesoft-lakebase-oauth-demo-design.md`
**Predecessor:** `docs/superpowers/plans/2026-08-13-mulesoft-lakebase-oauth-demo-phase3.md` (complete — both OAuth chains proven at the infra level; both Mule apps authored & xmllint-clean).

## Global Constraints

- **Free/CE only — no Anypoint account, no EE license.** Runtime = a public **Mule Kernel (CE)** Docker image. If any required connector turns out to be EE-gated, STOP and surface it (see Task 1).
- **No secrets committed.** SP client secret only via environment variable (`DATABRICKS_CLIENT_SECRET`) or git-ignored `config-local.yaml`/`.env`. Committed config keeps placeholders.
- **Live workspace facts come from `infra/connection-facts.md`** (profile `mulesoft-lakebase-demo`, host `<WORKSPACE_HOST>`, Data API URL, SP client id `7a31531d-…`, PG host, `demo.customers`). The FEVM sandbox expires **2026-09-15** — extend via FEVM if needed.
- **`sslmode=require`** on the JDBC connection.
- Both OAuth chains are already proven at the shell level by `infra/smoke-test.sh` — Phase 2 proves them **through Mule**.
- Docker maps container `8081` → host `8081`; each app is a separate image/container.

---

### Task 1: SPIKE — prove Mule Kernel CE can load both apps' connectors (the gate)

The make-or-break question: do the **Database connector** and **Object Store connector** run on the free CE runtime, or are they `@RequiresEnterpriseLicense`? (HTTP + its OAuth are known CE-safe; the EE `secure-configuration-property-module` is known EE-only and gets removed in Task 2.)

**Files:** none (throwaway probe) — record findings in the report.

- [ ] **Step 1: Pick and pull a Mule Kernel CE base image.**
  Candidates: `javastreets/mule` (Mule 4.4.0 Kernel) or `trellixa/mule`. Run `docker pull javastreets/mule:latest` (and note the exact Mule version it reports at startup). Confirm the image is CE/Kernel.
- [ ] **Step 2: Build a throwaway probe app** (or reuse a stripped copy of each real app) that declares just: an HTTP listener, a `db:config` + one `db:select`, and an `os:object-store` + `os:store`. `mvn clean package` it.
- [ ] **Step 3: Run it on the CE image** (`docker run -p 8081:8081 -v <jar>:/opt/mule/apps/...`), and read the startup logs.
  Expected PASS: app deploys, no `RequiresEnterpriseLicense` / "Enterprise License" / "EE license needed" errors for the DB and OS connectors.
- [ ] **Step 4: Record the verdict.**
  - If DB + OS load on CE → proceed with the full plan as written.
  - If DB connector is EE-gated → **STOP and surface**: the Data API app (HTTP+OAuth only) still runs fully on CE, but the JDBC app cannot run locally without EE/Anypoint. Options to present: (a) demo the Data API app on CE now + document the JDBC app as "authored, needs EE runtime"; (b) obtain an EE eval license/Anypoint access; (c) swap the JDBC app's DB connector for a plain JDBC approach if one is CE-viable. Do not guess — bring the finding back.
- [ ] **Step 5: Commit** — nothing to commit (probe is throwaway); the report captures the finding.

---

### Task 2: Replace EE secure-properties with plain config + env-var secret (both apps)

**Files:**
- Modify: `mule-data-api/src/main/mule/data-api.xml`, `mule-data-api/src/main/resources/config.yaml`, `mule-data-api/pom.xml`
- Modify: `mule-jdbc/src/main/mule/jdbc.xml`, `mule-jdbc/src/main/resources/config.yaml`, `mule-jdbc/pom.xml`

**Interfaces:** Produces apps whose properties load on CE with the SP secret injected from the `DATABRICKS_CLIENT_SECRET` environment variable.

- [ ] **Step 1: Remove the EE `mule-secure-configuration-property-module`** dependency from both `pom.xml` files (it forces an EE runtime).
- [ ] **Step 2: Add a `<configuration-properties file="config.yaml"/>`** element to each Mule XML (both apps currently lack the properties-loading element — Phase-3 reviews flagged this). Place it at the top of the config section.
- [ ] **Step 3: Change the secret reference** from `${secure::databricks.client.secret}` to an env-var read. In `config.yaml`, set `databricks.client.secret: "${DATABRICKS_CLIENT_SECRET}"` (Mule resolves system/env properties), OR reference `${DATABRICKS_CLIENT_SECRET}` directly in the OAuth config. Keep non-secret values as real values or placeholders.
- [ ] **Step 4: `mvn clean package`** both apps → confirm each builds a `*-mule-application.jar` with no EE-module resolution error. (This is the first real Maven build — reconcile any connector/driver version issues the Phase-3 poms flagged as "to be reconciled".)
- [ ] **Step 5: Commit** — `feat(mule): CE-compatible config (drop EE secure-props, load config.yaml, secret via env)`.

---

### Task 3: Dockerfiles + run scripts for both apps

**Files:**
- Create: `mule-data-api/Dockerfile`, `mule-jdbc/Dockerfile`
- Create: `docker-compose.yml` (root) or `run-local.sh` per app
- Create/modify: `.dockerignore`

**Interfaces:** Produces runnable containers; each exposes `8081`; secret passed via `-e DATABRICKS_CLIENT_SECRET=...` (from git-ignored `config-local.yaml`/`.env`, never baked into the image).

- [ ] **Step 1: Write each `Dockerfile`** — pattern (from the CE image research):
  ```dockerfile
  FROM javastreets/mule:<pinned-version>
  COPY target/*-mule-application.jar /opt/mule/apps/
  # CMD provided by base image (/opt/mule/bin/mule)
  ```
- [ ] **Step 2: Write `run-local.sh`** (or docker-compose) that: reads `DATABRICKS_CLIENT_SECRET` from a git-ignored `.env`/`config-local.yaml`, `mvn package`s the app, `docker build`s, and `docker run -p 8081:8081 -e DATABRICKS_CLIENT_SECRET=... <image>`. `set -euo pipefail`; never echo the secret.
- [ ] **Step 3: Verify** — the container starts and the app deploys (logs show the flows registered; HTTP listener bound on 8081). Do this for the Data API app first (CE-safe connectors).
- [ ] **Step 4: Commit** — `feat(docker): CE runtime Dockerfiles + local run scripts`.

---

### Task 4: Run the Data API app end-to-end (CRUD over OAuth)

**Files:** Create: `docs/phase2-run.md` (curl matrix + run notes).

**Interfaces:** Consumes Task 2/3 outputs. Proves the Data API OAuth chain THROUGH Mule.

- [ ] **Step 1: Start the Data API container** with the SP secret env var.
- [ ] **Step 2: Run the 5-call CRUD matrix** against `http://localhost:8081/customers` (list/get/create/update/delete) and confirm each maps to the Data API `/demo/customers` PostgREST call and returns expected data. Capture the commands + responses in `docs/phase2-run.md`.
- [ ] **Step 3: Verify OAuth refresh** — confirm the Mule OAuth client-credentials module fetches and reuses the Bearer token (check logs; optionally force a token expiry and confirm auto-refresh on 401).
- [ ] **Step 4: Commit** — `test(phase2): Data API app CRUD over OAuth verified in Docker`.

---

### Task 5: SPIKE + implement — JDBC token injection & credential mint (only if Task 1 cleared DB connector on CE)

Resolve the Phase-3-deferred spike: (1) the exact Databricks REST call that mints the Lakebase DB credential (CLI equivalent `databricks postgres generate-database-credential <endpoint>`), and (2) which Mule technique rotates the JDBC password — (a) Object Store-backed credential + reconnection strategy, (b) custom HikariCP `DataSource` with a credential supplier, (c) per-request dynamic DB config.

**Files:** Modify `mule-jdbc/src/main/mule/jdbc.xml` (refresh flow Step 2 + db:config password wiring), `mule-jdbc/pom.xml` if a DataSource lib is needed.

- [ ] **Step 1:** Confirm the credential-mint REST endpoint (inspect `databricks postgres generate-database-credential` with `--debug`/`-o json`, or the SDK) and implement it in the `refresh-lakebase-token` flow's Step 2 so `os:store` holds a real token.
- [ ] **Step 2:** Implement the chosen injection technique (start with (a): scheduled refresh into Object Store + a reconnection strategy on `db:config` that re-reads the stored token on connect). Keep the other two documented as alternatives.
- [ ] **Step 3:** Rebuild the jar; run in Docker.
- [ ] **Step 4:** Verify a `SELECT` CRUD call succeeds; then force a token expiry (or wait past the refresh interval) and confirm a subsequent call still succeeds — the real proof the rotation works.
- [ ] **Step 5: Commit** — `feat(mule): resolve JDBC token-refresh spike (mint + injection)`.

---

### Task 6: Run the JDBC app end-to-end (CRUD over rotating OAuth credential)

**Files:** Modify `docs/phase2-run.md` (add JDBC curl matrix).

- [ ] **Step 1: Start the JDBC container** (SP connects as its own Postgres role; `sslmode=require`).
- [ ] **Step 2: Run the 5-call CRUD matrix** against the JDBC app's listener; confirm rows in `demo.customers` change as expected (cross-check with `infra/smoke-test.sh` / psql).
- [ ] **Step 3: Verify** reconnection after Lakebase scale-to-zero (first call after idle may take ~100ms; confirm retry works).
- [ ] **Step 4: Commit** — `test(phase2): JDBC app CRUD + token rotation verified in Docker`.

---

### Task 7: Phase 2 documentation

**Files:** Modify `README.md`; finalize `docs/phase2-run.md`.

- [ ] **Step 1:** Document the no-Anypoint local-run story: Mule Kernel CE Docker image, `mvn package`, `docker build/run`, secret via env var, the curl matrices for both apps.
- [ ] **Step 2:** Record the Task-1 connector-licensing finding (what runs on CE) — reusable knowledge.
- [ ] **Step 3:** Update README's "how to run each phase" so Phase 2 points at `run-local.sh`/`docker-compose` + `docs/phase2-run.md`.
- [ ] **Step 4: Commit** — `docs: Phase 2 local-run guide (Mule Kernel CE + Docker)`.

---

## Notes / risks

- **Task 1 is a hard gate.** If the Database connector is EE-gated on CE, the JDBC app can't run locally without EE/Anypoint — the plan forks (Data API app still fully demos on CE). This is the one place we may need to come back to you.
- **Maven repos:** CE builds pull connectors from Maven Central / the public Mule repo. If any dependency resolves only from the MuleSoft EE Nexus (which needs credentials), that surfaces at `mvn package` (Task 2 Step 4) — swap for a CE-available equivalent or flag it.
- **Workspace TTL:** FEVM sandbox expires 2026-09-15; extend before running Phase 2 if the date has passed.
