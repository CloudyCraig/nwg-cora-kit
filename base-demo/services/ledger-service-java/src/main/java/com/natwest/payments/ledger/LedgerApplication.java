package com.natwest.payments.ledger;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * NatWest Payments demo - polyglot ledger-service entry point.
 *
 * <p>Spring Boot replacement for the Python ledger-service. The Splunk
 * OpenTelemetry Java agent (attached via the JAVA_TOOL_OPTIONS env var) provides
 * auto-instrumentation for the embedded Tomcat server, the JDBC client, and
 * the Spring Web layer, so this class itself contains zero observability
 * code - the demo's "polyglot tracing" story is told entirely by the agent.
 */
@SpringBootApplication
public class LedgerApplication {

    public static void main(String[] args) {
        SpringApplication.run(LedgerApplication.class, args);
    }
}
