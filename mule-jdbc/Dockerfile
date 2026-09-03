# ============================================================
# Stage 1: Build with Maven (JDK 11 required by mule-maven-plugin)
# Build context: repo root (set by docker-compose.yml)
# ============================================================
FROM maven:3.8-eclipse-temurin-11 AS builder

WORKDIR /workspace

# Mirror settings: mirrors everything to repository-master.mulesoft.org
# (repo.maven.apache.org and repository.mulesoft.org are blocked in corp env)
COPY maven-settings.xml /workspace/maven-settings.xml

# Copy app source — separate layers so pom-only changes get a dependency cache hit
COPY mule-jdbc/pom.xml         /workspace/mule-jdbc/pom.xml
COPY mule-jdbc/mule-artifact.json /workspace/mule-jdbc/mule-artifact.json
COPY mule-jdbc/src             /workspace/mule-jdbc/src

RUN cd /workspace/mule-jdbc \
    && mvn -s /workspace/maven-settings.xml clean package \
       -Dorg.slf4j.simpleLogger.log.org.apache.maven.cli.transfer.Slf4jMavenTransferListener=warn

# ============================================================
# Stage 2: Mule CE runtime (arm64-compatible)
# Pinned to the exact CE release tested in Task-1 spike.
# ============================================================
FROM javastreets/mule:CE-4.4.0-20221024

# Deploy the packaged Mule application
COPY --from=builder /workspace/mule-jdbc/target/*-mule-application.jar /opt/mule/apps/

EXPOSE 8081

# ARM64 SAFETY: The image's default entrypoint (/opt/mule/bin/mule) uses the
# Tanuki Service Wrapper, which has no arm64 binary ("hardware type not
# recognized"). Override with a direct Java invocation — same runtime, same JARs.
#
# Classpath and bootstrap class verified in Task-1 probe.
# Java wildcard expansion in -classpath is a JVM feature (not shell) so exec
# form is correct here.
ENTRYPOINT ["java", "-Dmule.home=/opt/mule", "-Dmule.base=/opt/mule", "-classpath", "/opt/mule/lib/boot/*:/opt/mule/conf", "org.mule.runtime.module.reboot.MuleContainerBootstrap"]
