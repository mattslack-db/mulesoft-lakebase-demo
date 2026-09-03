# JDBC Token Refresh Deep-Dive

This document covers the JDBC authentication chain (`mule-jdbc`, port 8082): why the
Lakebase database credential expires, how the scheduled refresh design works, the three
candidate injection techniques flagged as the Phase-2 spike, and the native-password
contrast.

## Why the JDBC Password Expires

Connecting to Lakebase over the Postgres wire protocol requires a **database credential**
— a short-lived token minted from a Databricks OAuth access token. The CLI equivalent is:

```bash
databricks postgres generate-database-credential \
  projects/<PROJECT_ID>/branches/production/endpoints/primary \
  --profile <PROFILE>
```

The minted credential has an observed TTL of approximately **1 hour** in the demo
environment. After it expires, any JDBC operation against an existing connection will fail
with an authentication error. A long-lived app must refresh the credential on a schedule.

This is in contrast to the native Postgres password (a static credential that never
expires) — see [Native Password Contrast](#native-password-contrast) below.

## Scheduled Refresh Design

The `refresh-lakebase-token` flow in `mule-jdbc/src/main/mule/jdbc.xml` implements a
two-step refresh:

```
Every 2700 seconds (45 min — ahead of the ~1 h TTL)
  Step 1: acquire a Databricks OAuth access token (client_credentials grant)
  Step 2: mint a Lakebase database credential from that token    ← Phase-2 spike
  Step 3: store the credential in the in-memory TokenStore
```

### Step 1: OAuth token acquisition

```xml
<set-payload value="#['grant_type=client_credentials&amp;client_id='
    ++ p('databricks.client.id')
    ++ '&amp;client_secret=' ++ p('databricks.client.secret')
    ++ '&amp;scope=all-apis']"/>
<http:request config-ref="Databricks_OAuth_HTTP" method="POST" path="/oidc/v1/token">
    <http:headers>#[{ 'Content-Type': 'application/x-www-form-urlencoded' }]</http:headers>
</http:request>
<set-variable variableName="databricksAccessToken" value="#[payload.access_token]"/>
```

The token URL is `https://${databricks.host}/oidc/v1/token`, scope `all-apis`.
Result: `vars.databricksAccessToken` holds a Bearer token.

### Step 2: Mint the Lakebase database credential (Phase-2 spike)

The CLI equivalent is `databricks postgres generate-database-credential <endpoint-path>`.
The Databricks Python SDK method is `w.postgres.generate_database_credential(endpoint_path)`.
The exact REST path to call from Mule (HTTP method, URL, request/response shape) must be
confirmed during Phase 2. The placeholder comment in `jdbc.xml` documents the candidate:

```
POST https://${databricks.host}/api/2.0/lakebase/credentials/generate
Authorization: Bearer {databricksAccessToken}
Body: { "endpoint_path": "${lakebase.endpointPath}" }
Expected response: { "token": "...", "expires_at": "..." }
```

### Step 3: Store in TokenStore

```xml
<os:store objectStore="TokenStore" key="lakebase-pg-token">
    <os:value>#[payload.token]</os:value>
</os:store>
```

The `TokenStore` is an in-memory Object Store (`persistent="false"`), so it does not
survive a JVM restart. On restart the scheduler fires immediately (default `initialDelay`
is 0) and repopulates it before the first request.

## DB Config and the Token Expression

The `Lakebase_DB` `db:config` reads the credential with a DataWeave fallback:

```xml
<db:config name="Lakebase_DB">
    <db:generic-connection
        url="jdbc:postgresql://${pg.host}:5432/${pg.database}?sslmode=require"
        driverClassName="org.postgresql.Driver"
        user="${pg.user}"
        password="#[vars.lakebaseToken default p('pg.bootstrap.token')]"/>
</db:config>
```

- `user` is the SP's Postgres role UUID — the same identity provisioned via
  `databricks_create_role()` in `infra/data-api-role.sql`.
- `sslmode=require` is enforced at the JDBC URL level.
- `pg.bootstrap.token` is a startup-time property used before the first scheduled
  refresh completes (Phase-2 detail).

## The Phase-2 Spike: Three Candidate Injection Techniques

Mule 4's `db:config` global element does **not** re-read a static property placeholder
at runtime. Once the connection pool is open, the password expression is evaluated at
startup and cached. Rotating the credential in a live pool requires one of three
approaches:

### (a) Object Store-backed credential + reconnection strategy

Pair the Object Store token with a Mule reconnection strategy that closes and reopens
pool connections when the credential is refreshed. On reconnect, the pool re-evaluates
the password expression, picking up the new token from the Object Store.

**Pro:** no custom Java; relies on standard Mule reconnection.
**Con:** requires that the reconnect event be triggered at the right time and that
pool eviction is reliable.

### (b) Custom HikariCP DataSource bean with a credential supplier

Provide a custom `DataSource` bean that wraps HikariCP and supplies a credential
function — a callback invoked on each connection borrow from the pool. The callback
reads the current token from the Object Store.

**Pro:** token is always fresh at connection borrow time; no pool restart needed.
**Con:** requires a custom Java class packaged into the Mule app; more complex.

### (c) Per-request dynamic DB config

Build a new `db:config` element inline per flow execution using a DataWeave config
factory, reading the current token from the Object Store on each request.

**Pro:** always uses the latest token; simplest to reason about.
**Con:** creates a new connection pool per request — expensive and not suitable for
production throughput; appropriate only for low-frequency demo scenarios.

The resolution of the spike (confirming which technique works cleanly in Mule's
runtime class loading and pool management model) is deferred to Phase 2.

## Native Password Contrast

Lakebase also supports a **native Postgres password** (a static credential that does not
expire). For JDBC, this trivialises the connection: set the password once and forget it.

The native password is intentionally **not used** in this demo. The demo's goal is to
prove OAuth token-based authentication works via the Postgres wire protocol — using a
native password would bypass that entirely. It is documented here only as a contrast to
clarify why the token-refresh complexity exists.

If static credentials are acceptable for a use case, the native password path requires
no scheduler, no Object Store, and no spike work — but it is not OAuth.
