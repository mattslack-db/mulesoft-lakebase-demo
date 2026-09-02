# Phase 2 — Data API App: CRUD over OAuth (Run Notes)

## Summary

End-to-end verification of the `mule-data-api` Mule 4 application proxying CRUD
operations against the Databricks Lakebase Data API using OAuth 2.0 client-credentials
(M2M). All five CRUD calls succeeded against live Lakebase (`demo.customers`).

**Verified:** 2026-09-02  
**Environment:** Docker Desktop (local), Mule CE 4.4.0-20221024, Lakebase workspace
`<WORKSPACE_HOST>`

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

- Token URL: `https://<WORKSPACE_HOST>/oidc/v1/token`
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
