# syntax=docker/dockerfile:1.7

############################################################
# Stage 1: build with Maven on JDK 21
############################################################
FROM maven:3.9-eclipse-temurin-21 AS build

WORKDIR /build

# Download dependencies first to maximise Docker layer caching.
COPY pom.xml ./
RUN mvn -B -q -DskipTests dependency:go-offline

COPY src ./src
RUN mvn -B -q -DskipTests package

############################################################
# Stage 2: download the Splunk OTel Java agent
#
# We use `curl -fL` (not `ADD url`) so a 404/redirect gets us a non-zero exit
# instead of writing the redirect HTML body to disk and silently producing a
# bogus jar that crashes the JVM at startup with "Error opening zip file".
# Pinning a known-good GA version keeps the demo build reproducible.
############################################################
FROM eclipse-temurin:21-jre AS otel-agent

RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Published to Maven Central as com.splunk:splunk-otel-javaagent.
ARG SPLUNK_OTEL_AGENT_VERSION=2.9.0
ARG SPLUNK_OTEL_AGENT_URL=https://repo1.maven.org/maven2/com/splunk/splunk-otel-javaagent/${SPLUNK_OTEL_AGENT_VERSION}/splunk-otel-javaagent-${SPLUNK_OTEL_AGENT_VERSION}.jar

RUN curl --fail --location --silent --show-error \
      --output /opt/splunk-otel-javaagent.jar \
      "${SPLUNK_OTEL_AGENT_URL}" \
 && test -s /opt/splunk-otel-javaagent.jar \
 && head -c 4 /opt/splunk-otel-javaagent.jar | od -An -tx1 \
      | tr -d ' \n' \
      | grep -qE '^(504b0304|504b0506|504b0708)' \
   || (echo "downloaded agent is not a valid zip/jar (PK magic bytes missing)"; exit 1)

############################################################
# Stage 3: runtime - JRE 21 with the fat jar + agent
############################################################
FROM eclipse-temurin:21-jre

RUN groupadd --system --gid 10001 app \
 && useradd  --system --uid 10001 --gid app --home /app --shell /sbin/nologin app

WORKDIR /app

COPY --from=build /build/target/ledger-service.jar /app/app.jar
COPY --from=otel-agent /opt/splunk-otel-javaagent.jar /opt/splunk-otel-javaagent.jar

USER app

ENV PORT=8080 \
    OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
    OTEL_LOGS_EXPORTER=none

EXPOSE 8080

# JAVA_TOOL_OPTIONS is the canonical way to attach an agent at runtime; the
# JVM reads it before main() is invoked so all Spring/JDBC/HTTP server spans
# are captured from the very first request.
ENV JAVA_TOOL_OPTIONS="-javaagent:/opt/splunk-otel-javaagent.jar -XX:MaxRAMPercentage=75.0"

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/actuator/health/liveness || exit 1

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
