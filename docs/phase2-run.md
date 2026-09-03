# Phase 2 — Data API App: CRUD over OAuth (Run Notes)

## Summary

End-to-end verification of the `mule-data-api` Mule 4 application proxying CRUD
operations against the Databricks Lakebase Data API using OAuth 2.0 client-credentials
(M2M). All five CRUD calls succeeded against live Lakebase (`demo.customers`).

**Verified:** 2026-09-02  
**Environment:** Docker Desktop (local), Mule CE 4.4.0-20221024, Lakebase workspace
`fe-sandbox-mulesoft-lakebase-demo.cloud.databricks.com`

---

## Prerequisites

```
# 1. Copy the env-var template and fill in your SP client secret
cp .env.example .env
# edit .env: set DATABRICKS_CLIENT_SECRET=<your-oauth-client-secret>

# 2. Build and start the Data API container
docker-compose up -d --build mule-data-api

# 3. Confirm DEPLOYED (wait ~25 s for Mule to boot)
docker-compose logs mule-data-api | tail -10
# Expected banner:
# * mule-data-api-1.0.0-SNAPSHOT-mule-application * default * DEPLOYED *
```

---

## CRUD Matrix (against `http://localhost:8081/customers`)

### 1 — LIST (GET all customers)

```bash
curl -s http://localhost:8081/customers
```

Response (`HTTP 200`):
```json
[
  {"id":1,"name":"Ada Lovelace","email":"ada@example.com","tier":"gold","created_at":"2026-09-01T16:09:07.313706+00:00"},
  {"id":2,"name":"Alan Turing","email":"alan@example.com","tier":"standard","created_at":"2026-09-01T16:09:07.313706+00:00"},
  {"id":3,"name":"Grace Hopper","email":"grace@example.com","tier":"gold","created_at":"2026-09-01T16:09:07.313706+00:00"}
]
```

---

### 2 — READ (GET single customer by id)

```bash
curl -s http://localhost:8081/customers/1
```

Response (`HTTP 200`):
```json
[{"id":1,"name":"Ada Lovelace","email":"ada@example.com","tier":"gold","created_at":"2026-09-01T16:09:07.313706+00:00"}]
```

---

### 3 — CREATE (POST new customer)

```bash
curl -s -X POST http://localhost:8081/customers \
  -H "Content-Type: application/json" \
  -d '{"name":"Test User","email":"test.user@example.com","tier":"standard"}'
```

Response (`HTTP 200`, `Prefer: return=representation` applied):
```json
[{"id":4,"name":"Test User","email":"test.user@example.com","tier":"standard","created_at":"2026-09-02T21:50:21.608129+00:00"}]
```

---

### 4 — UPDATE (PATCH customer tier)

```bash
curl -s -X PATCH http://localhost:8081/customers/4 \
  -H "Content-Type: application/json" \
  -d '{"tier":"gold"}'
```

Response (`HTTP 200`):
```json
[{"id":4,"name":"Test User","email":"test.user@example.com","tier":"gold","created_at":"2026-09-02T21:50:21.608129+00:00"}]
```

---

### 5 — DELETE (DELETE test row)

```bash
curl -s -o /dev/null -w "%{http_code}" -X DELETE http://localhost:8081/customers/4
```

Response: `200`

---

### Cleanup verification (follow-up LIST)

```bash
curl -s http://localhost:8081/customers
```

Response (`HTTP 200`, back to 3 seed rows):
```json
[
  {"id":1,"name":"Ada Lovelace","email":"ada@example.com","tier":"gold","created_at":"2026-09-01T16:09:07.313706+00:00"},
  {"id":2,"name":"Alan Turing","email":"alan@example.com","tier":"standard","created_at":"2026-09-01T16:09:07.313706+00:00"},
  {"id":3,"name":"Grace Hopper","email":"grace@example.com","tier":"gold","created_at":"2026-09-01T16:09:07.313706+00:00"}
]
```

---

## OAuth Verification

The Mule app uses **HTTP connector 1.7.3** + **OAuth 1.1.7** (`mule-service-oauth-2.1.2`)
in `client-credentials-grant-type` mode:

- Token URL: `https://fe-sandbox-mulesoft-lakebase-demo.cloud.databricks.com/oidc/v1/token`
- Scopes: `all-apis`
- Credentials: SP client ID + `DATABRICKS_CLIENT_SECRET` env var

Every HTTP 200 response carrying real Lakebase data proves the Bearer token was minted
and accepted. The Mule OAuth module fetches the token lazily on the first outbound request
and caches it until expiry (auto-refresh on next request). No token values appear in logs
or response bodies.

Start-up log confirms OAuth plugin loaded:
```
*  - OAuth : 1.1.7
*  - HTTP  : 1.7.3
* mule-data-api-1.0.0-SNAPSHOT-mule-application * default * DEPLOYED *
```

---

## Mule → Data API URL Mapping

| Mule endpoint | Data API call |
|--------------|--------------|
| `GET /customers` | `GET /demo/customers?order=id` |
| `GET /customers/{id}` | `GET /demo/customers?id=eq.{id}` |
| `POST /customers` | `POST /demo/customers` (Prefer: return=representation) |
| `PATCH /customers/{id}` | `PATCH /demo/customers?id=eq.{id}` (Prefer: return=representation) |
| `DELETE /customers/{id}` | `DELETE /demo/customers?id=eq.{id}` |

---

## Tear-down

```bash
docker-compose down
```

---

## Phase 2 — JDBC App: CRUD over Rotating OAuth Credential (Run Notes)

### Summary

End-to-end verification of the `mule-jdbc` Mule 4 application using the
`LakebaseDriver` proxy (Task 5) to execute CRUD operations against Lakebase
`demo.customers` via JDBC with an automatically rotating minted credential.
All five CRUD calls succeeded against live Lakebase.

**Verified:** 2026-09-03
**Environment:** Docker Desktop (local), Mule CE 4.4.0-20221024, Lakebase workspace
`fe-sandbox-mulesoft-lakebase-demo.cloud.databricks.com`
**Token rotation proof:** see [task-5-report.md](../.superpowers/sdd/2026-09-02-mulesoft-lakebase-oauth-demo-phase2/task-5-report.md) — 22 rotations, `GET /customers` remained HTTP 200 throughout.

---

## Prerequisites

```bash
# 1. Copy the env-var template and fill in your SP client secret
cp .env.example .env
# edit .env: set DATABRICKS_CLIENT_SECRET=<your-oauth-client-secret>

# 2. Build and start the JDBC container
docker-compose up -d --build mule-jdbc

# 3. Confirm DEPLOYED (wait ~25 s for Mule to boot)
docker-compose logs mule-jdbc | tail -10
# Expected banner:
# * mule-jdbc-1.0.0-SNAPSHOT-mule-application * default * DEPLOYED *
```

---

## Credential Rotation Mechanism

The `LakebaseDriver` proxy (Task 5, commit e5c3a7f) intercepts HikariCP pool
connections and substitutes the current credential from an `AtomicReference`
set by the `refresh-lakebase-token` scheduler (60 s interval for demo; restore
to 2700 s for production). Log evidence of live rotation appears as:

```
[LakebaseDriver] connect() cred_len=2295 cred_suffix=iGh5eA
[LakebaseDriver] connect() cred_len=2295 cred_suffix=rgdJig   ← suffix changed
[LakebaseDriver] connect() cred_len=2295 cred_suffix=Re-u_A   ← rotated again
```

---

## CRUD Matrix (against `http://localhost:8082/customers`)

### Mule CE 4.4.0 RETURNING * Workaround

`db:insert` uses JDBC `executeUpdate()`, which cannot consume a PostgreSQL
`RETURNING *` result set. `db:select` validates SQL type and rejects INSERT.
The fix (documented in `jdbc.xml` comments): INSERT/UPDATE without `RETURNING *`,
then a follow-up `db:select` to fetch the affected row.

---

### 1 — LIST (GET all customers)

```bash
curl -s http://localhost:8082/customers
```

Response (`HTTP 200`):
```json
[
  {"tier":"gold","name":"Ada Lovelace","created_at":"2026-09-01T16:09:07.313706","id":1,"email":"ada@example.com"},
  {"tier":"standard","name":"Alan Turing","created_at":"2026-09-01T16:09:07.313706","id":2,"email":"alan@example.com"},
  {"tier":"gold","name":"Grace Hopper","created_at":"2026-09-01T16:09:07.313706","id":3,"email":"grace@example.com"}
]
```

---

### 2 — READ (GET single customer by id)

```bash
curl -s http://localhost:8082/customers/1
```

Response (`HTTP 200`):
```json
[{"tier":"gold","name":"Ada Lovelace","created_at":"2026-09-01T16:09:07.313706","id":1,"email":"ada@example.com"}]
```

---

### 3 — CREATE (POST new customer)

```bash
curl -s -X POST http://localhost:8082/customers \
  -H "Content-Type: application/json" \
  -d '{"name":"JDBC Test","email":"jdbc.test@example.com","tier":"standard"}'
```

Response (`HTTP 200`, row returned via follow-up SELECT):
```json
[{"tier":"standard","name":"JDBC Test","created_at":"2026-09-03T19:35:22.473109","id":7,"email":"jdbc.test@example.com"}]
```

---

### 4 — UPDATE (PATCH customer tier)

```bash
curl -s -X PATCH http://localhost:8082/customers/7 \
  -H "Content-Type: application/json" \
  -d '{"tier":"gold"}'
```

Response (`HTTP 200`, row returned via follow-up SELECT):
```json
[{"tier":"gold","name":"JDBC Test","created_at":"2026-09-03T19:35:22.473109","id":7,"email":"jdbc.test@example.com"}]
```

---

### 5 — DELETE (DELETE test row)

```bash
curl -s -o /dev/null -w "%{http_code}" -X DELETE http://localhost:8082/customers/7
```

Response: `200`

---

### Cleanup verification (follow-up LIST)

```bash
curl -s http://localhost:8082/customers
```

Response (`HTTP 200`, back to 3 seed rows):
```json
[
  {"tier":"gold","name":"Ada Lovelace","created_at":"2026-09-01T16:09:07.313706","id":1,"email":"ada@example.com"},
  {"tier":"standard","name":"Alan Turing","created_at":"2026-09-01T16:09:07.313706","id":2,"email":"alan@example.com"},
  {"tier":"gold","name":"Grace Hopper","created_at":"2026-09-01T16:09:07.313706","id":3,"email":"grace@example.com"}
]
```

---

## HikariCP Startup Race (Pool Init vs. Credential Scheduler)

> **Scope of this note:** what is documented here is the **HikariCP pool-init /
> credential-scheduler startup race** inside the container — the window between
> container start and the first scheduler execution.  This is NOT a demonstration
> of Lakebase's own **service-side idle scale-to-zero** (branch suspension / resume);
> that scenario was not separately exercised in Phase 2 and remains untested
> (future work — see note at bottom of this section).

On container start, the `refresh-lakebase-token` scheduler fires at `startDelay=0`.
HikariCP pool initialization races against the first scheduler execution. During
startup, `LakebaseDriver.connect()` logs:

```
[LakebaseDriver] connect() called but no credential yet — returning null (startup race, benign)
```

HikariCP retries and succeeds once the scheduler sets the credential (~1–5 s).
No requests are lost: the first HTTP call to a listener endpoint after idle is
handled normally, with the pool expanding using the first available credential.
No manual retry is required; the benign null return causes HikariCP to
re-try the connection immediately.

**Lakebase service-side idle scale-to-zero (untested / future work):** Lakebase may
suspend a branch that has been idle for an extended period.  When a suspended branch
resumes, any JDBC connections already held by HikariCP's pool may become stale.
Handling this scenario (service-side suspension → resume → HikariCP detecting and
evicting stale connections) was **not demonstrated** in Phase 2.  Recommended future
work: configure HikariCP `keepaliveTime` and `connectionTimeout` appropriately, or
verify that `maxLifetime` eviction combined with the `LakebaseDriver` rotation cycle
is sufficient to recover from branch resumption without a container restart.

---

## Mule → JDBC Endpoint Mapping

| Mule endpoint | SQL operation |
|--------------|--------------|
| `GET /customers` | `SELECT ... ORDER BY id` |
| `GET /customers/{id}` | `SELECT ... WHERE id = :id` |
| `POST /customers` | `INSERT INTO ... VALUES (...)` + follow-up `SELECT` |
| `PATCH /customers/{id}` | `UPDATE ... SET tier = :tier WHERE id = :id` + follow-up `SELECT` |
| `DELETE /customers/{id}` | `DELETE FROM ... WHERE id = :id` |

---

## Tear-down (JDBC container)

```bash
docker-compose down mule-jdbc
# or to stop all services:
docker-compose down
```
