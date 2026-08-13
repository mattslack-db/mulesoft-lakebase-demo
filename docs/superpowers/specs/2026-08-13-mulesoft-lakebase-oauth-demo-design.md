# MuleSoft ↔ Lakebase OAuth Integration Demo — Design

**Date:** 2026-08-13
**Status:** Approved design; ready for implementation planning
**Audience / goal:** Internal POC / feasibility — prove that MuleSoft can integrate
with Databricks Lakebase (Autoscaling Postgres) using OAuth tokens, via **both**
connection styles, doing full CRUD.

## 1. Summary

Build a demo showing MuleSoft integrating with Lakebase over OAuth, two ways:

- **Data API path** — MuleSoft HTTP Requester + the OAuth 2.0 Client-Credentials
  module calling Lakebase's PostgREST-compatible Data API with a `Bearer` token.
  This is the clean, OAuth-native path.
- **JDBC path** — MuleSoft Database Connector talking the Postgres wire protocol,
  where the Postgres password is a short-lived Lakebase database credential
  (minted from an OAuth token, ~1h lifetime) that must be refreshed on a schedule.
  This is the higher-effort path and the more valuable feasibility proof.

Both apps front the **same** `customers` table and expose the **same** CRUD
surface, so the only difference a reviewer sees is the auth mechanism.

Delivered in three phases: **documented pattern → locally runnable → CloudHub deploy**.

## 2. Key technical findings (from `databricks-lakebase` skill references)

- **Data API auth:** every request carries `Authorization: Bearer <databricks-oauth-token>`.
  The token is obtained via an OAuth **client-credentials (M2M)** grant against the
  workspace OIDC token endpoint (`https://<workspace-host>/oidc/v1/token`, scope
  `all-apis`). Mule's OAuth module owns acquisition + refresh, so there is little to
  no custom token code on this path.
  - Each Databricks identity needs a matching Postgres role; for an M2M service
    principal the identity is the SP's application/client id. A role must be created
    and granted CRUD privileges on the demo table.
  - CRUD maps to PostgREST verbs: `GET ?col=eq.val`, `POST` (+ `Prefer: return=representation`),
    `PATCH ?col=eq.val`, `DELETE ?col=eq.val`.
- **JDBC auth:** the Postgres password is a Lakebase **database credential** minted
  from a Databricks OAuth token; it expires in ~1 hour. Mule 4's Database global
  config does **not** re-read a static property placeholder at runtime, so rotating
  the password requires a specific technique — this is the demo's one real unknown
  (see §5, Spike).
- **General:** always `sslmode=require`; 24h idle timeout guaranteed, longer not
  guaranteed → reconnection logic; scale-to-zero wake ~100ms → retry on first hit.
- **Native Postgres password** (no expiry) exists and is trivial for JDBC, but it is
  *not* OAuth — kept only as a documented contrast ("easy but not OAuth").

## 3. Architecture

### 3.1 Repo layout

```
mulesoft-lakebase-demo/
├── README.md                      # the OAuth story + how to run each phase
├── docs/
│   ├── architecture.md            # sequence diagrams: both auth chains
│   ├── data-api-oauth.md          # deep-dive: the clean HTTP+OAuth path
│   └── jdbc-token-refresh.md      # deep-dive: the fiddly JDBC path
├── infra/
│   ├── setup-lakebase.sh          # reuse-or-create project, enable Data API
│   ├── schema.sql                 # customers table + role + grants
│   └── seed.sql                   # sample rows
├── mule-data-api/                 # App 1  (HTTP + OAuth client-credentials)
│   ├── src/main/mule/data-api.xml
│   ├── src/main/resources/config-*.yaml
│   └── pom.xml
├── mule-jdbc/                     # App 2  (Database Connector + token refresh)
│   ├── src/main/mule/jdbc.xml
│   ├── src/main/resources/config-*.yaml
│   └── pom.xml
└── .gitignore                     # never commit SP secret / tokens
```

### 3.2 Demo domain

`customers` table: `id` (serial PK), `name` (text), `email` (text, unique),
`tier` (text), `created_at` (timestamptz default now()). Same table serves both apps.

### 3.3 Auth chains

**Data API path (App 1) — OAuth-native:**
```
Consumer → Mule HTTP Listener → [OAuth CC module: fetch/refresh Databricks token
            from /oidc/v1/token, scope=all-apis] → HTTP Requester with
            Authorization: Bearer <token> → Lakebase Data API (PostgREST) → Postgres
```

**JDBC path (App 2) — OAuth token as a rotating Postgres password:**
```
Scheduler (startup + every ~45 min) → [OAuth token from Databricks] →
   generate Lakebase DB credential (REST) → cache in Object Store
Consumer → Mule HTTP Listener → Database Connector (password = cached credential,
   sslmode=require) → Postgres
```

### 3.4 CRUD surface (identical across both apps)

| Operation | HTTP (Mule listener) | Data API (PostgREST)                     | JDBC (SQL)                              |
|-----------|----------------------|------------------------------------------|-----------------------------------------|
| List      | `GET /customers`     | `GET /customers?order=id`                | `SELECT ... ORDER BY id`                |
| Read      | `GET /customers/{id}`| `GET /customers?id=eq.{id}`              | `SELECT ... WHERE id = :id`             |
| Create    | `POST /customers`    | `POST /customers` (`Prefer: return=representation`) | `INSERT ... RETURNING *`     |
| Update    | `PATCH /customers/{id}`| `PATCH /customers?id=eq.{id}`          | `UPDATE ... WHERE id = :id RETURNING *` |
| Delete    | `DELETE /customers/{id}`| `DELETE /customers?id=eq.{id}`        | `DELETE ... WHERE id = :id`             |

## 4. Phasing & deliverables

**Phase 3 — Documented pattern (built first; no Mule install needed):**
- Provision or reuse a Lakebase project; apply `schema.sql` + `seed.sql`; enable the
  Data API; create the SP's Postgres role + grants.
- Author annotated Mule flow XML for both apps and the `docs/` deep-dives with
  sequence diagrams.
- Done when: a reviewer can read the repo and understand both OAuth chains with real
  endpoint/URL shapes filled in from the live project.

**Phase 2 — Locally runnable:**
- Import both apps into Anypoint Studio (or run via the Mule Maven plugin), point at
  the live Lakebase project, drive CRUD with `curl`/Postman against local listeners.
- Resolve the JDBC token-injection spike for real.
- Done when: both apps do full CRUD against Lakebase over OAuth locally.

**Phase 1 — CloudHub / Anypoint deploy:**
- Externalize secrets via Anypoint secure properties / CloudHub secure config;
  deploy notes; confirm token refresh survives in the managed runtime.
- Done when: deployment guide + externalized-config reference complete.

**Prerequisites captured before Phase 2 (not before Phase 3):**
- A Databricks **profile** the user selects (never auto-selected).
- Confirmation of **Anypoint Studio / local Mule runtime** availability.

## 5. Key implementation risk — JDBC token injection (Spike)

Mule 4's Database global config does not re-read a static property placeholder at
runtime. The **first implementation task** is a short spike to confirm which
technique rotates the JDBC password cleanly:

- (a) Object Store-backed credential + reconnection strategy that re-reads on connect;
- (b) custom HikariCP `DataSource` bean with a credential supplier;
- (c) per-request dynamic DB config built from the cached token.

Also to verify during the spike: the exact Databricks REST call that mints the
database credential (CLI equivalent: `databricks postgres generate-database-credential
<endpoint>`; SDK: `w.postgres.generate_database_credential`).

## 6. Error handling

- **Data API:** OAuth module handles token refresh (incl. refresh-on-401); map
  PostgREST HTTP errors (401/403/404/409) to clean Mule responses; surface Postgres
  constraint violations (e.g. duplicate email) as 409.
- **JDBC:** reconnection strategy for scale-to-zero wake-ups and expired-token
  reconnect; scheduler logs each refresh; a failed refresh keeps the last good token
  and retries.
- **Both:** validate input at the HTTP boundary (required fields, email shape) before
  touching Lakebase.

## 7. Testing / verification (feasibility-appropriate)

- **Infra smoke script:** mint a token, run `SELECT 1` (JDBC) and one Data API `curl`
  GET — prove both auth chains work *outside* Mule first, to de-risk before Mule.
- **Mule:** MUnit flows per CRUD operation where practical; at minimum a documented
  manual `curl` test matrix (5 CRUD calls × 2 apps) that must pass in Phase 2.
- **JDBC refresh proof:** confirm a CRUD call still succeeds after a forced token
  expiry — the real proof that refresh works.

## 8. Security notes

- SP client id/secret never committed: git-ignored `config-local.yaml` for dev,
  Anypoint secure properties / CloudHub secure config for deploy.
- `sslmode=require` on all Postgres connections.
- Least privilege: grant the SP role only the CRUD privileges it needs on the demo
  table/schema (consider a dedicated schema rather than `public`).

## 9. Out of scope (YAGNI)

- No APIkit / RAML-driven API layer — a thin HTTP listener is enough for feasibility.
- No unified single-app toggle (rejected Approach B) — separate apps make the auth
  contrast clear.
- No production hardening beyond what proves feasibility (no rate limiting, no
  multi-tenant RLS beyond a documented note).
