# Phase 2 Local-Run Guide — Mule Kernel CE + Docker (No Anypoint)

Both OAuth chains — HTTP/Bearer via PostgREST and JDBC with a rotating Lakebase
credential — run on the **free Mule Kernel Community Edition** inside Docker containers.
No Anypoint account, no Anypoint Studio, no Mule EE license is required.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Docker Desktop | Current stable version; tested on arm64 (Apple Silicon) |
| `.env` file with secret | See [Secret Setup](#secret-setup) below |
| Databricks workspace / SP | See `infra/connection-facts.md` for non-secret values |
| **No** Java / Maven locally | Both apps build inside Docker (multi-stage Dockerfile) |
| **No** Anypoint account | Free Mule Kernel CE image is pulled from Docker Hub |

The base runtime image is `javastreets/mule:CE-4.4.0-20221024` (Community Edition /
Kernel, no license check). It is pulled automatically during `docker compose build`.

---

## Secret Setup

The only secret needed is the Databricks M2M service-principal client secret.

```bash
# 1. Copy the template
cp .env.example .env

# 2. Fill in your SP client secret
#    Edit .env and set:
#    DATABRICKS_CLIENT_SECRET=<your-oauth-client-secret>
```

`.env` is git-ignored and is never baked into the Docker images.  If you prefer to
export the variable in your shell rather than use a file, that also works — the
`docker-compose.yml` passthrough picks it up either way.

Non-secret values (workspace host, SP client ID, Lakebase endpoint) live in
`mule-data-api/src/main/resources/config.yaml` and
`mule-jdbc/src/main/resources/config.yaml` (already filled in from
`infra/connection-facts.md`).

---

## Build and Run

### Start both apps together

```bash
docker compose up --build
```

First run downloads the Maven and Mule CE images and resolves all connector JARs
(~3–5 minutes on a fast connection).  Subsequent runs reuse Docker layer caches and
start in under a minute.

### Start one app at a time

```bash
# Data API app (HTTP + OAuth client-credentials → PostgREST)
docker compose up --build mule-data-api

# JDBC app (Database connector + rotating credential)
docker compose up --build mule-jdbc
```

### Port mapping

| Service | Host port | What it exposes |
|---|---|---|
| `mule-data-api` | `localhost:8081` | REST CRUD via Data API + OAuth |
| `mule-jdbc` | `localhost:8082` | REST CRUD via JDBC + rotating credential |

Both apps bind Mule's default internal port `8081`; the JDBC app is remapped to
`8082` on the host only.

### Confirm deployment (~25 s after container starts)

```bash
docker compose logs mule-data-api | tail -10
# Look for:
# * mule-data-api-1.0.0-SNAPSHOT-mule-application * default * DEPLOYED *

docker compose logs mule-jdbc | tail -10
# Look for:
# * mule-jdbc-1.0.0-SNAPSHOT-mule-application * default * DEPLOYED *
```

### Tear-down

```bash
docker compose down
```

---

## Quick Smoke Test

**Data API app (port 8081):**

```bash
curl -s http://localhost:8081/customers
```

**JDBC app (port 8082):**

```bash
curl -s http://localhost:8082/customers
```

Both should return the three seed rows as JSON with HTTP 200:

```json
[
  {"id":1,"name":"Ada Lovelace","email":"ada@example.com","tier":"gold","created_at":"..."},
  {"id":2,"name":"Alan Turing","email":"alan@example.com","tier":"standard","created_at":"..."},
  {"id":3,"name":"Grace Hopper","email":"grace@example.com","tier":"gold","created_at":"..."}
]
```

---

## Full CRUD Matrices

Complete five-operation (LIST / READ / CREATE / UPDATE / DELETE) curl sequences with
live response bodies are documented in [`docs/phase2-run.md`](phase2-run.md):

- **Data API app** — `http://localhost:8081/customers` — see the Data API section
- **JDBC app** — `http://localhost:8082/customers` — see the JDBC section (includes
  `RETURNING *` workaround note and credential-rotation evidence)

Both matrices were verified against live Lakebase on 2026-09-02/03 with all five
operations returning HTTP 200.

---

## CE Porting Lessons

These are the key findings from porting both apps from an Anypoint-first design to
the free Mule Kernel CE runtime.  Captured here so the next CE-based Mule project
can skip the same investigation.

---

### Lesson 1 — Free Runtime: Mule Kernel CE via Public Docker Image

The free Mule Kernel CE runtime is available as the Docker image
`javastreets/mule:CE-4.4.0-20221024` (source: https://github.com/javastreets/mule-docker-image).
No Anypoint account is needed to pull or run it.

Key connector licensing findings from the Task-1 spike
([task-1-report.md](../.superpowers/sdd/2026-09-02-mulesoft-lakebase-oauth-demo-phase2/task-1-report.md)):

| Connector | CE status |
|---|---|
| HTTP 1.7.3 | CE-OK (no `@RequiresEnterpriseLicense`) |
| OAuth 1.1.7 (`mule-oauth-module`) | CE-OK |
| Database 1.14.0 | **CE-OK** — not EE-gated (source-confirmed) |
| Object Store 1.2.1 | CE-OK |
| `secure-configuration-property-module` | **EE-only** — must be removed |

The EE `secure-configuration-property-module` was removed from both `pom.xml` files.
Secrets are now injected via the `${DATABRICKS_CLIENT_SECRET}` environment variable,
which Mule 4 resolves in `config.yaml` values at startup (commit `29562fa`).

---

### Lesson 2 — Build Gotchas

**JDK 11 is required.** Both `mule-maven-plugin:4.10.0` and the CE runtime expect
Java 11.  JDK 17, 21, and 25 all fail at build or runtime:

| JDK | Failure |
|---|---|
| 25 | `PluginContainerException` in mule-maven-plugin class-loader |
| 17 | `javax.activation.MimetypesFileTypeMap` not found (removed post JDK 8) |
| **11** | BUILD SUCCESS |

The multi-stage Dockerfiles pin stage 1 to `maven:3.8-eclipse-temurin-11`; the CE
runtime image (`javastreets/mule:CE-4.4.0-20221024`) ships Temurin JDK 11.

**Maven repositories blocked in this corporate environment.**
Both `repository.mulesoft.org` and `repo.maven.apache.org` resolve to `127.0.0.1`
(corporate security policy).  Fix: `maven-settings.xml` at repo root mirrors
everything (`mirrorOf="*"`) to
`https://repository-master.mulesoft.org/nexus/content/groups/public`, which proxies
both MuleSoft releases AND Maven Central and requires no credentials.  All connector
JARs resolved cleanly (commit `29562fa`, confirmed in Task-2 report).

**`mule-maven-plugin:4.10.0` requires `mule-artifact.json`.**
`mule-maven-plugin:3.7.2` (the original pom version) was upgraded to `4.10.0` for
Maven 3.8+ compatibility.  The newer plugin requires a `mule-artifact.json` at the
app root; neither app had one.  Minimal CE content:

```json
{
  "minMuleVersion": "4.4.0",
  "requiredProduct": "MULE"
}
```

`"requiredProduct": "MULE"` = CE, no EE license check (commit `29562fa`).

---

### Lesson 3 — ARM64 Runtime Workaround

The `javastreets/mule` image's default entrypoint (`/opt/mule/bin/mule`) uses the
Tanuki Service Wrapper, which has no ARM64 binary.  On Apple Silicon it exits
immediately with `"hardware type not recognized"`.

**Fix:** override `ENTRYPOINT` to start Mule directly via Java, bypassing the wrapper.
The runtime is identical — same JARs, same extension loading path:

```dockerfile
ENTRYPOINT ["java",
  "-Dmule.home=/opt/mule",
  "-Dmule.base=/opt/mule",
  "-classpath", "/opt/mule/lib/boot/*:/opt/mule/conf",
  "org.mule.runtime.module.reboot.MuleContainerBootstrap"]
```

Java's wildcard expansion in `-classpath` is a JVM feature (not a shell feature), so
the exec-form JSON array is correct here — no shell wrapping required.  Verified in
the Task-1 probe and used in both production Dockerfiles (commit `f8d2589`).

---

### Lesson 4 — JDBC Credential Rotation: Proxy JDBC Driver

Mule's `db:config` / `db:generic-connection` evaluates the `password` DataWeave
expression **once at HikariCP pool creation time**.  A static password will expire
when the Lakebase credential TTL (~1 hour) elapses; the pool cannot pick up a new
credential without a restart.

**Three approaches were evaluated; only the proxy driver works on CE:**

| Approach | Result |
|---|---|
| (a) Reconnection strategy | Rejected: HikariCP stores the resolved password string; reconnection retries reuse it — `setPassword()` has no effect |
| **(b) Proxy JDBC Driver** | **Used** — intercepts every `connect()` call (proxy-Driver variant of custom datasource-level credential injection) |
| (c) Per-request dynamic `config-ref` | Rejected: EE-only feature in Mule 4 CE |

**`LakebaseDriver` proxy architecture** (commit `e5c3a7f`):

1. `LakebaseDriver` implements `java.sql.Driver` with the URL scheme `jdbc:lakebase://`.
2. `db:generic-connection` is configured with `driverClassName="...LakebaseDriver"`,
   a placeholder password, and a `jdbc:lakebase://…` URL.
3. HikariCP calls `LakebaseDriver.connect()` for **every new physical connection**.
4. `connect()` ignores HikariCP's stored placeholder and reads
   `LakebaseDataSource.getPassword()` — the current `AtomicReference<String>` value —
   instead.
5. The `refresh-lakebase-token` scheduler calls `setPassword(newToken)` after each
   Lakebase credential mint (`POST /api/2.0/postgres/credentials`).
6. The next new physical connection (on pool expansion or after `maxLifetime` eviction)
   uses the rotated credential automatically.

**Rotation was proven empirically**: 22 credential rotations at 60 s intervals, with
`GET /customers` returning HTTP 200 throughout and `cred_suffix` values in the logs
changing after each `setPassword()` call.  See
[task-5-report.md](../.superpowers/sdd/2026-09-02-mulesoft-lakebase-oauth-demo-phase2/task-5-report.md).

**Spring module path was abandoned**: `mule-spring-module:1.3.5` requires
`org.springframework.security.*` to be visible in its plugin classloader, but
Spring Security is not bundled and Mule's classloader isolation prevents exporting it
from app dependencies.  The proxy driver approach avoids the Spring registry entirely.
The failed Spring beans XML is preserved at `mule-jdbc/docs/spring-beans-ABANDONED.xml`.

---

### Lesson 5 — Mule CE 4.4.0 Cannot Use `RETURNING *`

Mule CE 4.4.0's `db:insert` uses JDBC `executeUpdate()`, which cannot consume a
PostgreSQL `RETURNING *` result set.  `db:select` validates the SQL type and rejects
non-SELECT statements.

**Workaround for CREATE and UPDATE** (commit `00fd619`):

```
POST /customers  →  INSERT INTO demo.customers (…) VALUES (…)
                     then SELECT … WHERE email = :email ORDER BY id DESC LIMIT 1

PATCH /customers/{id}  →  UPDATE demo.customers SET tier = :tier WHERE id = :id
                           then SELECT … WHERE id = :id
```

Request fields must be captured into variables **before** the DML step because
`payload` is replaced by the DML result after `db:insert` / `db:update`.

This pattern is in `mule-jdbc/src/main/mule/jdbc.xml` (the `create-customer` and
`update-customer` flows).

---

## Cross-References

| Phase 2 task | Report |
|---|---|
| Task 1 — CE connector gate spike | [task-1-report.md](../.superpowers/sdd/2026-09-02-mulesoft-lakebase-oauth-demo-phase2/task-1-report.md) |
| Task 2 — CE-compatible config + builds | [task-2-report.md](../.superpowers/sdd/2026-09-02-mulesoft-lakebase-oauth-demo-phase2/task-2-report.md) (commit `29562fa`) |
| Task 3 — Dockerfiles + docker-compose | [task-3-report.md](../.superpowers/sdd/2026-09-02-mulesoft-lakebase-oauth-demo-phase2/task-3-report.md) (commits `f8d2589`, `9aa9f0a`) |
| Task 4 — Data API CRUD verified | [task-4-report.md](../.superpowers/sdd/2026-09-02-mulesoft-lakebase-oauth-demo-phase2/task-4-report.md) (commit `5ceb901`) |
| Task 5 — JDBC token mint + injection | [task-5-report.md](../.superpowers/sdd/2026-09-02-mulesoft-lakebase-oauth-demo-phase2/task-5-report.md) (commits `3a4f9c9`, `e5c3a7f`) |
| Task 6 — JDBC CRUD matrix | [task-6-report.md](../.superpowers/sdd/2026-09-02-mulesoft-lakebase-oauth-demo-phase2/task-6-report.md) (commit `00fd619`) |
| Full CRUD matrices | [docs/phase2-run.md](phase2-run.md) |
