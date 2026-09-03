package com.example.mulesoft.lakebase;

import java.sql.*;
import java.util.Properties;
import java.util.logging.Logger;

/**
 * Proxy JDBC Driver for Lakebase PostgreSQL connections.
 *
 * Problem being solved:
 *   HikariCP (used internally by db:generic-connection) stores the password at
 *   pool creation time. When it needs a new PHYSICAL connection it calls
 *   Driver.connect(url, info) — but info["password"] is whatever was stored at
 *   pool init. Updating an AtomicReference AFTER the pool is created has no
 *   effect because HikariCP never re-reads a DataWeave expression.
 *
 * Solution:
 *   This proxy driver intercepts connect() and REPLACES the password in the
 *   Properties with LakebaseDataSource.getPassword() — the current value of the
 *   AtomicReference — before delegating to the real PostgreSQL driver.
 *   The pool can be configured with any placeholder password; every physical
 *   connection uses the credential that is current AT THAT MOMENT.
 *
 * Rotation propagation:
 *   1. Refresh flow fires → setPassword(newToken) updates the AtomicReference.
 *   2. HikariCP eventually creates a new physical connection (on pool init,
 *      expansion, or after maxLifetime eviction).
 *   3. HikariCP calls connect() on this driver.
 *   4. connect() reads CURRENT_PASSWORD.get() — returns the NEW token.
 *   5. New connection authenticated with the new credential.
 *
 * URL scheme: jdbc:lakebase://host:port/db → delegates to jdbc:postgresql://
 *
 * Registration: the static initialiser calls DriverManager.registerDriver() so
 * Class.forName("...LakebaseDriver") in db:generic-connection is sufficient.
 */
public class LakebaseDriver implements Driver {

    private static final Logger LOG = Logger.getLogger(LakebaseDriver.class.getName());

    static {
        try {
            DriverManager.registerDriver(new LakebaseDriver());
        } catch (SQLException e) {
            throw new ExceptionInInitializerError(e);
        }
    }

    // -----------------------------------------------------------------------
    // Driver interface
    // -----------------------------------------------------------------------

    @Override
    public Connection connect(String url, Properties info) throws SQLException {
        if (!acceptsURL(url)) return null;

        String current = LakebaseDataSource.getPassword();
        if (current == null || current.isEmpty()) {
            // During the startup connectivity test the scheduler has not fired yet.
            // Return null so DriverManager skips this driver rather than throwing.
            // The first real db:select (after startDelay=0 refresh fires) will succeed.
            System.out.println("[LakebaseDriver] connect() called but no credential yet — returning null (startup race, benign)");
            return null;
        }

        // Translate URL scheme
        String pgUrl = url.replaceFirst("^jdbc:lakebase:", "jdbc:postgresql:");

        Properties pgInfo = new Properties();
        if (info != null) pgInfo.putAll(info);
        pgInfo.setProperty("password", current);

        // Print credential suffix to stdout (appears in docker logs) so rotation
        // can be verified empirically — the suffix changes after setPassword().
        String suffix = current.length() >= 6
                ? current.substring(current.length() - 6)
                : current;
        System.out.println(String.format(
                "[LakebaseDriver] connect() cred_len=%d cred_suffix=%s",
                current.length(), suffix));

        // Ensure the real PostgreSQL driver is loaded
        try {
            Class.forName("org.postgresql.Driver");
        } catch (ClassNotFoundException e) {
            throw new SQLException("PostgreSQL driver not found on classpath", e);
        }

        return DriverManager.getConnection(pgUrl, pgInfo);
    }

    @Override
    public boolean acceptsURL(String url) throws SQLException {
        return url != null && url.startsWith("jdbc:lakebase:");
    }

    @Override
    public DriverPropertyInfo[] getPropertyInfo(String url, Properties info) {
        return new DriverPropertyInfo[0];
    }

    @Override public int getMajorVersion() { return 1; }
    @Override public int getMinorVersion() { return 0; }
    @Override public boolean jdbcCompliant() { return false; }

    @Override
    public Logger getParentLogger() throws SQLFeatureNotSupportedException {
        throw new SQLFeatureNotSupportedException("java.util.logging not used");
    }
}
