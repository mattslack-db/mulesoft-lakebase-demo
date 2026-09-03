package com.example.mulesoft.lakebase;

import javax.sql.DataSource;
import java.io.IOException;
import java.io.InputStream;
import java.io.PrintWriter;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.sql.SQLFeatureNotSupportedException;
import java.util.Properties;
import java.util.concurrent.atomic.AtomicReference;
import java.util.logging.Logger;

/**
 * Technique (b): Custom DataSource that creates JDBC connections on demand,
 * reading the Lakebase database credential from a static AtomicReference updated
 * by the Mule refresh-lakebase-token flow via java:invoke-static.
 *
 * This sidesteps Mule 4's db:generic-connection limitation where the password
 * expression is evaluated once at pool initialization. Instead, every connection
 * borrow reads the latest minted credential from CURRENT_PASSWORD.
 *
 * URL and user are set once via Spring property injection; password is rotated
 * at runtime via setPassword(String) called from the Mule refresh flow.
 *
 * Alternatives documented but not implemented:
 *   (a) OS-backed credential + reconnection strategy — Mule's reconnection
 *       strategies fire only on connection failure, not scheduled expiry; and
 *       db:generic-connection evaluates the password expression at HikariCP
 *       pool creation time, not per-borrow. Rotation would require deliberately
 *       poisoning the pool and relying on recreation — fragile and unsupported.
 *
 *   (c) Per-request dynamic db:config — Mule 4 CE does not support dynamic
 *       config-ref expressions on db:select/insert/etc. in the open-source
 *       runtime; dynamic config resolution is an EE-only feature. Scripting the
 *       full JDBC call in Groovy bypasses db:config entirely and was rejected
 *       because the gate requires db:config.
 */
public class LakebaseDataSource implements DataSource {

    /** Password shared across all instances; updated by refresh flow. */
    private static final AtomicReference<String> CURRENT_PASSWORD =
            new AtomicReference<>("");

    /** JDBC URL; injected by Spring at startup from Mule config properties. */
    private String jdbcUrl;

    /** Database username (Postgres role = SP client-ID UUID). */
    private String user;

    private PrintWriter logWriter;

    // -----------------------------------------------------------------------
    // Spring property setters (URL and user are stable; password rotates)
    // -----------------------------------------------------------------------

    public void setJdbcUrl(String jdbcUrl) {
        this.jdbcUrl = jdbcUrl;
    }

    public void setUser(String user) {
        this.user = user;
    }

    // -----------------------------------------------------------------------
    // Called by java:invoke-static from the refresh-lakebase-token flow
    // -----------------------------------------------------------------------

    /**
     * Return the current credential. Called by the DataWeave expression in
     * {@code db:generic-connection password} at HikariCP pool creation time
     * (Mule lazily initialises the pool on the first db:select/insert/etc).
     * The scheduler fires at startDelay=0 so this returns the minted credential
     * before the first HTTP request hits any CRUD flow.
     *
     * @return the current Lakebase database credential token, or "" before the
     *         first refresh fires
     */
    public static String getPassword() {
        return CURRENT_PASSWORD.get();
    }

    /**
     * Update the shared credential. Called by the Mule refresh flow via
     * {@code <java:invoke-static>} after each successful credential mint.
     *
     * The refresh flow materialises the JSON response into a concrete
     * {@code java.util.Map} (via {@code output application/java} on the
     * payload) before extracting the token field. This ensures the argument
     * reaching this method is a concrete {@code java.lang.String}, not one of
     * Mule 4's lazy cursor types which the Java module cannot coerce.
     *
     * @param password the Lakebase database credential token
     */
    public static void setPassword(String password) {
        CURRENT_PASSWORD.set(password);
    }

    // -----------------------------------------------------------------------
    // DataSource implementation — creates a fresh connection per call
    // -----------------------------------------------------------------------

    @Override
    public Connection getConnection() throws SQLException {
        return getConnection(user, CURRENT_PASSWORD.get());
    }

    @Override
    public Connection getConnection(String username, String password) throws SQLException {
        try {
            Class.forName("org.postgresql.Driver");
        } catch (ClassNotFoundException e) {
            throw new SQLException("PostgreSQL JDBC driver not found on classpath", e);
        }
        if (password == null || password.isEmpty()) {
            throw new SQLException(
                    "No Lakebase credential available yet — refresh flow has not fired");
        }
        Properties props = new Properties();
        props.setProperty("user", username);
        props.setProperty("password", password);
        props.setProperty("sslmode", "require");
        return DriverManager.getConnection(jdbcUrl, props);
    }

    // -----------------------------------------------------------------------
    // Boilerplate DataSource methods
    // -----------------------------------------------------------------------

    @Override
    public PrintWriter getLogWriter() throws SQLException { return logWriter; }

    @Override
    public void setLogWriter(PrintWriter out) throws SQLException { this.logWriter = out; }

    @Override
    public void setLoginTimeout(int seconds) throws SQLException {}

    @Override
    public int getLoginTimeout() throws SQLException { return 0; }

    @Override
    public Logger getParentLogger() throws SQLFeatureNotSupportedException {
        throw new SQLFeatureNotSupportedException("java.util.logging not used");
    }

    @Override
    public <T> T unwrap(Class<T> iface) throws SQLException {
        if (iface.isInstance(this)) return iface.cast(this);
        throw new SQLException("Not a wrapper for " + iface.getName());
    }

    @Override
    public boolean isWrapperFor(Class<?> iface) throws SQLException {
        return iface.isInstance(this);
    }
}
