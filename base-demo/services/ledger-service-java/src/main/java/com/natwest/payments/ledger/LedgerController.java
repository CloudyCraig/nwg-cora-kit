package com.natwest.payments.ledger;

import io.opentelemetry.api.trace.Span;
import jakarta.servlet.http.HttpServletRequest;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.stereotype.Controller;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.client.RestTemplate;
import org.springframework.web.client.RestClientException;

import java.time.OffsetDateTime;
import java.util.*;
import java.util.concurrent.*;

/**
 * Drop-in replacement for the Python ledger-service /process endpoint.
 *
 * <p>The contract matches the Python template service exactly: same request
 * payload, same response shape, same simulated-error semantics. Splunk APM
 * sees this service as a Java application, but the upstream
 * {@code payment-initiation-service} fan-out call shows up as an unbroken
 * trace because the Splunk Java agent reads the W3C {@code traceparent}
 * header and continues the trace.
 *
 * <p>Per request the service:
 * <ol>
 *   <li>Reads business attributes off the JSON body and tags them onto the
 *       current server span (Tag Spotlight pivots downstream).</li>
 *   <li>Sleeps for a Gaussian-distributed "work" duration.</li>
 *   <li>Inserts one {@link LedgerEntry} row and runs a per-account
 *       {@code SELECT SUM(amount)} - the JDBC instrumentation produces two
 *       client spans against the inferred Postgres node.</li>
 *   <li>Optionally adds a configurable extra DB-side latency
 *       ({@code DB_LATENCY_MS}) for the "slow query" demo incident.</li>
 *   <li>Calls each {@code DOWNSTREAMS} entry over HTTP. {@code RestTemplate}
 *       is auto-instrumented so each call appears as a child span.</li>
 *   <li>Optionally returns 500 with probability {@code ERROR_RATE}.</li>
 * </ol>
 */
@Controller
public class LedgerController {

    private static final Logger log = LoggerFactory.getLogger(LedgerController.class);
    private static final Random RAND = new Random();

    private final LedgerEntryRepository repo;
    private final RestTemplate http;
    private final ExecutorService fanout;

    @Value("${ledger.serviceName:ledger-service}")
    private String serviceName;

    @Value("${ledger.serviceTier:ledger}")
    private String serviceTier;

    @Value("${ledger.errorRate:0.005}")
    private double errorRate;

    @Value("${ledger.latencyMsMean:30}")
    private double latencyMsMean;

    @Value("${ledger.latencyMsStddev:10}")
    private double latencyMsStddev;

    @Value("${ledger.dbLatencyMs:0}")
    private long dbLatencyMs;

    @Value("${ledger.downstreams:}")
    private String downstreams;

    @Value("${ledger.downstreamPort:8080}")
    private int downstreamPort;

    public LedgerController(LedgerEntryRepository repo) {
        this.repo = repo;
        this.http = new RestTemplate();
        this.fanout = Executors.newFixedThreadPool(8);
    }

    @GetMapping(value = {"/healthz", "/health"}, produces = MediaType.APPLICATION_JSON_VALUE)
    @ResponseBody
    public Map<String, Object> healthz() {
        return Map.of("status", "ok", "service", serviceName);
    }

    @GetMapping(value = "/readyz", produces = MediaType.APPLICATION_JSON_VALUE)
    @ResponseBody
    public Map<String, Object> readyz() {
        return Map.of("status", "ready", "service", serviceName);
    }

    @PostMapping(value = "/process",
            consumes = MediaType.APPLICATION_JSON_VALUE,
            produces = MediaType.APPLICATION_JSON_VALUE)
    @Transactional
    public ResponseEntity<Map<String, Object>> process(@RequestBody(required = false) Map<String, Object> body,
                                                       HttpServletRequest req) {
        if (body == null) body = new HashMap<>();

        String paymentId = String.valueOf(body.getOrDefault("payment_id", UUID.randomUUID().toString()));
        String scenario = String.valueOf(body.getOrDefault("scenario", "generic"));
        long amountMinor = parseLong(body.get("amount_minor_units"), 0L);
        String scheme = upperOrNull(body.get("scheme"));
        String currency = nullableString(body.get("currency"));
        String channel = nullableString(body.get("channel"));
        String countryPair = nullableString(body.get("country_pair"));
        String originator = nullableString(body.get("originator_country"));
        String beneficiary = nullableString(body.get("beneficiary_country"));
        String amountBucket = nullableString(body.get("amount_bucket"));
        String customerId = nullableString(body.get("customer_id"));
        // Mirror the Python service: default to "bronze" so the dimension is
        // always populated in Splunk APM, even when the upstream caller is an
        // older client that hasn't been re-rolled yet.
        String customerTierRaw = nullableString(body.get("customer_tier"));
        String customerTier = customerTierRaw == null ? "bronze" : customerTierRaw.toLowerCase(Locale.ROOT);
        if (!customerTier.equals("bronze") && !customerTier.equals("silver") && !customerTier.equals("gold")) {
            customerTier = "bronze";
        }

        Span span = Span.current();
        if (span != null && span.getSpanContext().isValid()) {
            span.setAttribute("payment.id", paymentId);
            span.setAttribute("payment.scenario", scenario);
            span.setAttribute("payment.amount_minor_units", amountMinor);
            span.setAttribute("service.tier", serviceTier);
            span.setAttribute("customer.tier", customerTier);
            if (customerId != null) span.setAttribute("customer.id", customerId);
            if (scheme != null) span.setAttribute("payment.scheme", scheme);
            if (currency != null) span.setAttribute("payment.currency", currency);
            if (channel != null) span.setAttribute("payment.channel", channel);
            if (countryPair != null) span.setAttribute("payment.country_pair", countryPair);
            if (originator != null) span.setAttribute("payment.originator_country", originator);
            if (beneficiary != null) span.setAttribute("payment.beneficiary_country", beneficiary);
            if (amountBucket != null) span.setAttribute("payment.amount_bucket", amountBucket);
        }

        double workMs = Math.max(0.0, latencyMsMean + RAND.nextGaussian() * latencyMsStddev);
        sleepMs((long) workMs);

        // DB writes: one INSERT + one SUM. Both produce JDBC client spans
        // attributed to the inferred Postgres node in Splunk APM.
        String accountId = paymentId.length() > 16 ? paymentId.substring(0, 16) : paymentId;
        repo.save(new LedgerEntry(
                paymentId, accountId, scheme == null ? "UNKNOWN" : scheme,
                amountMinor, currency == null ? "GBP" : currency,
                "D", OffsetDateTime.now()));
        long balance = repo.sumAmountByAccount(accountId);

        // Optional injected DB latency for the "db-slow" incident demo.
        //
        // The latency is issued as a real `SELECT pg_sleep(...)` query
        // through the same Hibernate connection so it appears as:
        //   * a slow JDBC client span (Splunk APM trace waterfall),
        //   * a top-N entry in pg_stat_statements (Splunk APM Database
        //     Query Performance + ITSI nwpay_l4_postgres KPIs),
        //   * an "active backend" + held row-lock for the duration
        //     (postgres_exporter / native postgresqlreceiver metrics).
        // We clamp here as a defence in depth: the chaos triggers cap at
        // ~5 s, but a typo in DB_LATENCY_MS shouldn't be able to wedge
        // the connection pool for the rest of the day. Anything above
        // 30 s is silently capped and logged.
        if (dbLatencyMs > 0) {
            long capped = Math.min(dbLatencyMs, 30_000L);
            if (capped != dbLatencyMs) {
                log.warn("db-slow: DB_LATENCY_MS={} exceeds 30s cap; using 30000", dbLatencyMs);
            }
            try {
                repo.chaosPgSleep(capped / 1000.0);
            } catch (RuntimeException ex) {
                // Cannot fail the payment because the demo's chaos
                // latency is half-broken; fall back to a Java sleep so
                // we still degrade APM service health, and log loudly so
                // the operator notices the partial signal.
                log.warn("db-slow: chaosPgSleep failed ({}); falling back to Java sleep", ex.toString());
                sleepMs(capped);
            }
        }

        int downstreamErrors = 0;
        List<Map<String, Object>> downstreamResults = new ArrayList<>();
        List<String> targets = new ArrayList<>();
        if (downstreams != null && !downstreams.isBlank()) {
            for (String d : downstreams.split(",")) {
                String t = d.trim();
                if (!t.isEmpty()) targets.add(t);
            }
        }
        if (!targets.isEmpty()) {
            Map<String, Object> fwd = new HashMap<>(body);
            fwd.put("from", serviceName);
            List<Future<Map<String, Object>>> futures = new ArrayList<>();
            for (String svc : targets) {
                futures.add(fanout.submit(() -> callDownstream(svc, fwd)));
            }
            for (Future<Map<String, Object>> f : futures) {
                try {
                    Map<String, Object> r = f.get(5, TimeUnit.SECONDS);
                    downstreamResults.add(r);
                    if (!Boolean.TRUE.equals(r.get("ok"))) downstreamErrors++;
                } catch (Exception e) {
                    downstreamResults.add(Map.of("service", "?", "ok", false, "status", 0));
                    downstreamErrors++;
                }
            }
        }

        if (RAND.nextDouble() < errorRate) {
            if (span != null && span.getSpanContext().isValid()) {
                span.setAttribute("error", true);
                span.setAttribute("error.type", "simulated");
            }
            log.error("simulated_error payment_id={} scheme={}", paymentId, scheme);
            return ResponseEntity.status(500).body(Map.of(
                    "service", serviceName,
                    "payment_id", paymentId,
                    "error", "simulated"));
        }

        log.info("processed payment_id={} scheme={} customer_tier={} customer_id={} work_ms={} balance_minor={} downstreams={} errors={}",
                paymentId, scheme, customerTier, customerId == null ? "-" : customerId,
                Math.round(workMs), balance, targets.size(), downstreamErrors);

        Map<String, Object> resp = new HashMap<>();
        resp.put("service", serviceName);
        resp.put("payment_id", paymentId);
        resp.put("scenario", scenario);
        resp.put("scheme", scheme);
        resp.put("customer_tier", customerTier);
        resp.put("work_ms", Math.round(workMs * 10.0) / 10.0);
        resp.put("balance_minor_units", balance);
        resp.put("downstream_results", downstreamResults);
        return ResponseEntity.ok(resp);
    }

    private Map<String, Object> callDownstream(String svc, Map<String, Object> payload) {
        String url = "http://" + svc + ":" + downstreamPort + "/process";
        try {
            ResponseEntity<Map> resp = http.postForEntity(url, payload, Map.class);
            return Map.of(
                    "service", svc,
                    "status", resp.getStatusCode().value(),
                    "ok", resp.getStatusCode().is2xxSuccessful());
        } catch (RestClientException e) {
            log.warn("downstream_call_failed service={} error={}", svc, e.getMessage());
            return Map.of("service", svc, "status", 0, "ok", false);
        }
    }

    private static void sleepMs(long ms) {
        if (ms <= 0) return;
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    private static String upperOrNull(Object v) {
        if (v == null) return null;
        String s = v.toString().trim();
        return s.isEmpty() ? null : s.toUpperCase(Locale.ROOT);
    }

    private static String nullableString(Object v) {
        if (v == null) return null;
        String s = v.toString().trim();
        return s.isEmpty() ? null : s;
    }

    private static long parseLong(Object v, long def) {
        if (v == null) return def;
        try {
            if (v instanceof Number n) return n.longValue();
            return Long.parseLong(v.toString());
        } catch (NumberFormatException e) {
            return def;
        }
    }
}
