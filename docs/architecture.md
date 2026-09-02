# Architecture

This repo demonstrates two OAuth integration patterns between MuleSoft and Databricks Lakebase.
Both apps expose identical CRUD endpoints over the `demo.customers` table; the only difference
is how authentication is handled at the backend.

## Why Two Apps?

A single app with a toggle would obscure the auth contrast behind conditional branching.
Separate apps — `mule-data-api` (port 8081) and `mule-jdbc` (port 8082) — make each pattern
self-contained and independently reviewable: open either XML file and the full story is there
without switching context.

## Chain 1: Data API / OAuth-native (App 1 — `mule-data-api`)

MuleSoft's built-in OAuth client-credentials module handles token acquisition and refresh
automatically. Every HTTP request to the Lakebase Data API carries an
`Authorization: Bearer` token; PostgREST validates it, extracts the `.sub` claim (the SP's
client ID), and does `SET ROLE` before executing the SQL.

```mermaid
sequenceDiagram
    participant C as Consumer
    participant ML as Mule App 1 (port 8081)
    participant OI as Databricks OIDC
    participant DA as Lakebase Data API (PostgREST)
    participant PG as Postgres

    C->>ML: HTTP request /customers
    Note over ML: OAuth CC module checks token cache
    ML->>OI: POST /oidc/v1/token (client_credentials, scope=all-apis)
    OI-->>ML: access_token + expires_in=3600
    ML->>DA: HTTP request + Authorization: Bearer {access_token}
    Note over DA: Validate Databricks JWT, extract .sub = SP_CLIENT_ID
    DA->>PG: SET ROLE "SP_CLIENT_ID"; execute SQL
    PG-->>DA: result rows
    DA-->>ML: JSON (PostgREST response)
    ML-->>C: HTTP response
```

The token URL is `https://${databricks.host}/oidc/v1/token` with scope `all-apis`.
The OAuth CC module handles refresh transparently when the token nears expiry (1 h TTL).

See `docs/data-api-oauth.md` for the full deep-dive, including the SP role setup requirement.

## Chain 2: JDBC / token-as-password (App 2 — `mule-jdbc`)

A scheduled flow refreshes a short-lived Lakebase database credential every 45 minutes
and caches it in an in-memory Object Store. The JDBC Database Connector uses the cached
credential as the Postgres password with `sslmode=require`.

```mermaid
sequenceDiagram
    participant S as Scheduler
    participant RF as refresh-lakebase-token flow
    participant OI as Databricks OIDC
    participant LR as Lakebase REST API
    participant TS as TokenStore (in-memory)
    participant C as Consumer
    participant ML as Mule App 2 (port 8082)
    participant PG as Postgres

    loop Every 45 minutes
        S->>RF: trigger
        RF->>OI: POST /oidc/v1/token (client_credentials, scope=all-apis)
        OI-->>RF: access_token
        RF->>LR: generate-database-credential for endpoint (Phase 2 spike)
        LR-->>RF: short-lived credential (~1 h TTL)
        RF->>TS: store under key "lakebase-pg-token"
    end

    C->>ML: HTTP request /customers
    Note over ML,TS: Phase-2 spike — request-time token read is the target design; current authored app uses a bootstrap-token fallback
    ML->>TS: read "lakebase-pg-token"
    TS-->>ML: short-lived credential
    ML->>PG: JDBC (user=SP_UUID, password=credential, sslmode=require)
    PG-->>ML: rows / affected count
    ML-->>C: HTTP response
```

The mechanism for rotating the password in an already-open connection pool is the
**Phase-2 spike** (three candidates annotated in `mule-jdbc/src/main/mule/jdbc.xml`).
See `docs/jdbc-token-refresh.md` for the full deep-dive.

## CRUD Surface

Both apps expose identical HTTP endpoints. The backend verb differs by auth chain.

| Operation | Mule listener            | Data API (PostgREST)                                   | JDBC (SQL)                                |
|-----------|--------------------------|--------------------------------------------------------|-------------------------------------------|
| List      | `GET /customers`         | `GET /demo/customers?order=id`                         | `SELECT ... ORDER BY id`                  |
| Read      | `GET /customers/{id}`    | `GET /demo/customers?id=eq.{id}`                       | `SELECT ... WHERE id = :id`               |
| Create    | `POST /customers`        | `POST /demo/customers` + `Prefer: return=representation` | `INSERT ... RETURNING *`                |
| Update    | `PATCH /customers/{id}`  | `PATCH /demo/customers?id=eq.{id}` + `Prefer: return=representation` | `UPDATE ... WHERE id=:id RETURNING *` |
| Delete    | `DELETE /customers/{id}` | `DELETE /demo/customers?id=eq.{id}` (returns 204)      | `DELETE ... WHERE id = :id`               |
