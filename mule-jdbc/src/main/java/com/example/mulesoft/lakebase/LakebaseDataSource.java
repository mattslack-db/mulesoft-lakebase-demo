package com.example.mulesoft.lakebase;

import java.util.concurrent.atomic.AtomicReference;

/**
 * Static credential store for the Lakebase database credential.
 *
 * Role in the rotation architecture:
 *   - getPassword(): read by LakebaseDriver.connect() at physical connection
 *     creation time.  Returns whatever setPassword() last stored.
 *   - setPassword(String): called by java:invoke-static in the Mule
 *     refresh-lakebase-token flow after each successful credential mint.
 *
 * Together, these two methods bridge the Mule flow world (scheduled refresh)
 * with the JDBC layer (LakebaseDriver), without requiring the Spring module or
 * any Mule registry wiring:
 *
 *   db:generic-connection driverClassName="...LakebaseDriver"
 *       → HikariCP calls LakebaseDriver.connect() for each new physical conn
 *       → LakebaseDriver reads LakebaseDataSource.getPassword() at that moment
 *       → After setPassword(newCred), the NEXT new physical connection uses newCred
 *       → Rotation propagates without restart.
 */
public final class LakebaseDataSource {

    private static final AtomicReference<String> CURRENT_PASSWORD =
            new AtomicReference<>("");

    private LakebaseDataSource() {}

    /**
     * Return the current credential. Called by LakebaseDriver.connect() at
     * physical connection creation time so every new connection uses the latest
     * minted credential.
     */
    public static String getPassword() {
        return CURRENT_PASSWORD.get();
    }

    /**
     * Update the shared credential. Called by the Mule refresh flow via
     * {@code <java:invoke-static>} after each successful credential mint.
     *
     * The parameter is named "password" in source but compiled as "arg0" without
     * the javac -parameters flag. The java:invoke-static java:args map must use
     * key "arg0" to match the compiled bytecode parameter name.
     *
     * Mule 4 passes the argument as a concrete java.lang.String after the refresh
     * flow materialises the HTTP JSON response with
     *   {@code output application/java --- payload}
     * before extracting the token field.
     *
     * @param password fresh Lakebase database credential token (java.lang.String)
     */
    public static void setPassword(String password) {
        CURRENT_PASSWORD.set(password);
    }
}
