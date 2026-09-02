# MuleSoft ↔ Lakebase OAuth Demo

A proof-of-concept showing MuleSoft integrating with Databricks Lakebase (autoscaling
Postgres) using OAuth tokens — two ways, same CRUD surface.

## The OAuth Story

Lakebase supports two OAuth-authenticated access paths: a PostgREST HTTP Data API where
MuleSoft's built-in OAuth client-credentials module carries a Bearer token on every
request, and the Postgres wire protocol (JDBC) where the token is minted into a
short-lived database credential used as the JDBC password. Both paths use the same
Databricks M2M service principal with the `all-apis` scope; the difference is whether
the token is carried as an HTTP header or as a Postgres password that must be refreshed
on a schedule before it expires (~1 hour).

## Repo Map

```
mulesoft-lakebase-demo/
├── README.md                               # this file
├── docs/
│   ├── architecture.md                     # sequence diagrams: both auth chains + CRUD table
│   ├── data-api-oauth.md                   # deep-dive: HTTP + OAuth client-credentials
│   └── jdbc-token-refresh.md              # deep-dive: JDBC + token-as-password refresh
├── infra/
│   ├── connection-facts.md                 # non-secret workspace/endpoint values
│   ├── schema.sql                          # demo.customers table definition
│   ├── seed.sql                            # three seed rows
│   ├── grants.sql                          # JDBC path role grants (placeholder)
│   ├── data-api-role.sql                   # Data API SP role via databricks_auth extension
│   ├── data-api-setup.sh                   # automated Data API + SP role setup
│   └── smoke-test.sh                       # end-to-end proof: both auth chains green
├── mule-data-api/                          # App 1: HTTP Requester + OAuth CC module
│   ├── src/main/mule/data-api.xml
│   ├── src/main/resources/config.yaml
│   └── pom.xml
├── mule-jdbc/                              # App 2: Database Connector + token refresh
│   ├── src/main/mule/jdbc.xml
│   ├── src/main/resources/config.yaml
│   └── pom.xml
└── .gitignore                              # config-local.yaml / secrets never committed
```

Non-secret connection values (workspace host, endpoint, Data API URL) live in
`infra/connection-facts.md`. Secrets (`SP_CLIENT_SECRET`, etc.) live only in
`config-local.yaml`, which is git-ignored.

## Status

Both auth chains are **confirmed working** via `infra/smoke-test.sh`:

```
✓ JDBC/psql auth chain OK
✓ Data API auth chain OK
```

## How to Run

### Phase 3 — Verify the infrastructure (current phase)

Prerequisite: Databricks CLI authenticated with the `mulesoft-lakebase-demo` profile,
`config-local.yaml` present with SP credentials.

```bash
bash infra/smoke-test.sh
```

Both lines should print `OK`. This proves the Lakebase project, schema, SP role, and
Data API are correctly configured before Mule is involved.

To (re-)apply the full Data API and SP role setup:

```bash
bash infra/data-api-setup.sh mulesoft-lakebase-demo <SP_CLIENT_ID> mulesoft-lakebase-demo
```

### Phase 2 — Run locally (forthcoming)

Import `mule-data-api/` and `mule-jdbc/` into Anypoint Studio (or run via
`mvn mule:run`) and drive CRUD via `curl` against `localhost:8081` and `localhost:8082`.
Phase 2 also resolves the JDBC token-injection spike (see `docs/jdbc-token-refresh.md`).

### Phase 1 — CloudHub deploy (forthcoming)

Externalize secrets via Anypoint secure properties / CloudHub secure config and deploy
both apps to a managed Mule runtime.

## Documentation

- [Architecture + sequence diagrams](docs/architecture.md)
- [Data API OAuth deep-dive](docs/data-api-oauth.md)
- [JDBC token refresh deep-dive](docs/jdbc-token-refresh.md)
- [Design spec](docs/superpowers/specs/2026-08-13-mulesoft-lakebase-oauth-demo-design.md)
- [Phase 3 implementation plan](docs/superpowers/plans/2026-08-13-mulesoft-lakebase-oauth-demo-phase3.md)
