# NatWest Card Payments - ITSI service tree

This directory holds the ITSI (IT Service Intelligence) artifacts for the
demo. The plan that drives the design is at
`/Users/mserieys/.cursor/plans/natwest_payments_itsi_service_tree_a7adbe4c.plan.md`.

```
itsi/
  service-tree.yaml                               source of truth: services + KPIs + entities + KPI base searches
  glass-table/natwest-payments-overview.xml       L1 glass-table dashboard
  correlation-searches/                           every *.json upserted as an ITSI saved search
    o11y_to_itsi.json                             Splunk Observability -> ITSI alert bridge
    payments_excessive_declines_by_tier.json      SIEM: nwpay_audit declines per tier
    payments_madrid_latency_breach.json           SIEM: OTel-trace Madrid p95 > 1500ms
    payments_api_gateway_5xx_breach.json          SIEM: OTel-trace api-gateway 5xx rate > 5% over 5m
    payments_service_latency_slo_breach.json      SIEM: OTel-trace per-service p99 SLO breach (ledger/payment/sanctions/fraud/gateway)
    payments_ledger_jdbc_errors.json              SIEM: ledger-service JDBC/JPA error storm (>=20 errors / 5m)
    payments_settlement_consumer_idle.json        SIEM: settlement-service consumer span count near zero (Kafka chain broken)
    chaos_injection_audit.json                    SIEM: one notable per nwpay:chaos inject/clear (Event Analytics feed)
    chaos_off_change_window.json                  SIEM: chaos injections outside the change window
    spa_network_connection_changed.json           SIEM: browser-side network type degradation from RUM audit beacon
  aggregation-policies/                           every *.json upserted as an ITSI Episode policy
    payments_episode_policy.json                  Roll APM + SIEM notables into one Episode per service
scripts/
  07-itsi-bootstrap.sh                            idempotent installer (runs the Python helper)
  lib/itsi_bootstrap.py                           translates the YAML manifest into ITSI REST objects
  lib/itsi_data_probe.sh                          probe whether the data sources ITSI expects are populated
terraform/
  itsi_alert_bridge.tf                            o11y webhook integration + HEC SG rule (gated, opt-in)
```

## 1. Tree shape (recap)

The tree mirrors the platform architecture diagram - `Channels` -> `API
Gateway` -> four capability tiers (Experience, Payment, Business, Ledger
& Settlement) -> external `Payment Networks`:

```
L1: NatWest Card Payments
├── L3: API Gateway
│   ├── L2: Payment Services           (init / validate / route / fee / status)
│   ├── L2: Experience Services        (user / profile / limits / notification)
│   ├── L2: Business Services          (account / beneficiary / sanctions / fraud)
│   └── L2: Ledger & Settlement        (ledger / settle / recon / report + PG / Kafka)
├── L2: Payment Networks               (FPS, BACS, CHAPS, SWIFT, SEPA, Cheque)
│   └── linked from Payment, Experience, Business and Ledger & Settlement tiers
├── L2: Digital Customer Experience    (ThousandEyes synthetics)
├── L2: Synthetic Business Outcomes
├── L2: Customer Tier Experience       (merged Bronze / Silver / Gold)
├── L2: Payments by Location
├── L5: AWS cloud-plane security       (GuardDuty / CloudTrail)
├── L3: ~24 microservices (payment-init, fraud, ledger, ..., 6 networks)
└── L4: EKS, postgres, redis, kafka, otel-collector, splunk-enterprise
```

Recommended defaults from the plan are baked in:

- Tiers are modelled as **peer L2 services**, not KPI dimensions, so a Bronze
  decline spike turns Bronze red while Gold/Silver stay green.
- Each external payment scheme is its own **L3 microservice** (Faster
  Payments, Bacs, CHAPS, SWIFT, SEPA, Cheque clearing) with per-scheme
  p99 + error-rate KPIs, all rolling up into the **Payment Networks**
  L2 tile. Payment, Experience, Business and Ledger & Settlement tiers each
  depend on it for health-score roll-up. The previous "Network adapters"
  rollup has been retired.
- **No pod-level entities.** Service-level rolls up across replicas via OTel
  `service.name`.
- **L4 services are now fully populated.** Earlier iterations of the tree
  carried `nwpay_l4_redis`, `nwpay_l4_postgres`, and `nwpay_l4_kafka` as
  empty stubs. They now each carry three KPIs sourced from
  `kbs_redis_health`, `kbs_postgres_health`, and `kbs_kafka_health`
  respectively. See section 8 below.

## 2. One-time data-source wiring

ITSI needs to be able to query the spans, logs, RUM events, and synthetic
events the rest of the platform produces. The shape:

```
EKS workloads ──► splunk-otel-collector ──► Splunk Observability (spans, metrics, RUM, profiling)
                                       └─► Splunk Enterprise HEC index=main
                                             ├─ sourcetype="otel:logs"     (already wired)
                                             ├─ sourcetype="otel:traces"   (NEW: collector/values.yaml)
                                             └─ sourcetype="otel:metrics"  (NEW: collector/values.yaml)

Splunk Observability ──► Log Observer Connect ──► Splunk Enterprise index=splunkrum
                                                    ├─ event="page_view"      (RUM)
                                                    └─ event="synthetic_run"  (Synthetics)
```

### 2.1 Enable trace + metric fan-out from the OTel collector

`collector/values.yaml` now sets `splunkPlatform.tracesEnabled: true` and
`splunkPlatform.metricsEnabled: true`. After applying it:

```bash
helm upgrade --reuse-values splunk-otel-collector \
  splunk-otel-collector-chart/splunk-otel-collector \
  -n splunk-otel \
  -f collector/values.yaml
```

Trade-off: HEC ingest doubles vs. logs-only. Acceptable at the demo's
~30 ev/s peak; turn off if the HEC license becomes a bottleneck and use the
Splunk Observability -> Splunk Platform connector instead.

### 2.2 Wire Log Observer Connect (LOC) for RUM + Synthetics + infra logs

In Splunk Observability Cloud:

1. **Logs** → **Logs connections** → **Add new connection**
   (Log Observer Connect; not under Data Management).
2. Choose **Splunk Enterprise** and complete the guided setup.
3. Splunk URL: `https://itsi.splunk-observability.com:8089` (the demo box)
4. Service account: `lo-connect` (provisioned by `scripts/lib/bootstrap_loc_user.sh`
   on the Splunk EC2 instance).
5. Index allow-list on the Splunk Enterprise role: `main`, `splunkrum`, `nwpay_infra`

Once LOC is connected, Splunk Enterprise federates:

- RUM events and synthetic runs in `index=splunkrum` (KPIs
  `kbs_rum_page_load`, `kbs_synthetic_success`)
- Trace-correlated app logs in `index=main` (APM **Logs for this trace**)
- Infrastructure logs in `index=nwpay_infra` (Postgres / Redis / Kafka /
  nginx; APM **Logs** tab on `postgres` / `redis` / `kafka` service nodes)

If the LOC integration was created before `nwpay_infra` routing landed,
re-run the LOC wizard or edit the saved-search index allow-list. Full
runbook: [`docs/operations/infra-logs-loc.md`](../docs/operations/infra-logs-loc.md).

### 2.3 Verify

```bash
scripts/lib/itsi_data_probe.sh
```

Output reports OK or WARN per data source so you know exactly what to fix.
KPIs whose data is missing show "no data" in ITSI but do not block the rest
of the tree.

## 3. Bootstrap the service tree

```bash
# Required env (sourced from .env if present):
#   TF_VAR_splunk_enterprise_admin_password = <Splunk admin password>

# Optional: see the rendered JSON without touching the API.
scripts/07-itsi-bootstrap.sh --dry-run | jq '.services | length'

# Real run.
scripts/07-itsi-bootstrap.sh

# Or directly on the box:
ssh ec2-user@itsi.splunk-observability.com
cd /repo && scripts/07-itsi-bootstrap.sh --local
```

The script:

1. Opens an SSH tunnel to splunkd (8089 is operator-CIDR-only on the SG).
2. Posts each KPI base search, then services in dependency-correct order
   (leaves first, L1 last), then entities, then the L1 glass-table view.
3. Logs `[ok]` / `[fail]` per object; failures don't abort the run so a
   partial tree always lands.

Re-runs are safe: every object has a deterministic `_key` and the script
upserts via PUT-if-exists / POST-if-new.

## 4. The L1 glass table

`itsi/glass-table/natwest-payments-overview.xml` is the **single source of
truth** for the executive overview. The bootstrap script publishes it in
**two** places so executives can find it whether they reach for "Dashboards"
or "Glass Tables":

| Path | What it is | Where it appears |
|------|------------|------------------|
| Simple XML dashboard | The original 19-row, 47-panel `natwest_payments_overview.xml` POSTed to `/servicesNS/nobody/itsi/data/ui/views` | Splunk Web → ITSI app → **Dashboards** menu |
| Native ITSI Glass Table v3 | Auto-converted Dashboard Studio JSON (via `scripts/lib/glass_table_convert.py`) POSTed as a `glass_table` ITSI object with `_key=nwpay_glass_table_overview` | Splunk Web → ITSI app → **Service Insights → Glass Tables** menu |
| **Customer journey** (optional second bundle) | `itsi/glass-table/natwest-customer-journey.xml` → view `natwest_customer_journey` + native `_key=nwpay_glass_table_customer_journey` | Same menus; RUM, auth, tier, journey friction, recent outcomes |

Open them at:

```
# Simple XML
https://itsi.splunk-observability.com:8000/en-US/app/itsi/natwest_payments_overview

# Native ITSI Glass Table (v3 / Dashboard Studio)
https://itsi.splunk-observability.com:8000/en-US/app/itsi/glass_table?id=nwpay_glass_table_overview
# Customer journey (native)
https://itsi.splunk-observability.com:8000/en-US/app/itsi/glass_table?id=nwpay_glass_table_customer_journey
# Or just navigate via the menu:
#   ITSI → Service Insights → Glass Tables → "NatWest Card Payments - Glass Table"
#   or "NatWest Customer Journey"
```

**Blank page on Glass Table?** The ITSI `glass_table` view reads the object id from the **`id`** query parameter (same as the KV `_key`), not `savedGlassTableId`. A link like `glass_table?savedGlassTableId=nwpay_glass_table_overview&action=view` can load the app chrome but leave the canvas empty. Use `glass_table?id=nwpay_glass_table_overview` (locale prefix `en-GB` / `en-US` is fine). If it is still blank, open the browser developer console (F12) on that page and check for JavaScript errors from a malformed panel definition.

The converter is **deterministic** and re-run on every bootstrap, so any
edits you make to the Simple XML automatically flow into the native glass
table on the next `scripts/07-itsi-bootstrap.sh`. To regenerate the JSON
artefact for inspection without touching Splunk:

```bash
python3 scripts/lib/glass_table_convert.py
# writes itsi/glass-table/natwest-payments-overview.glass-table.json
```

To skip the native install (e.g. in a Splunk Enterprise instance without
ITSI), pass `--native-glass-table=''` to `itsi_bootstrap.py` or set the env
var when invoking the wrapper.

Panels:

1. L1 health-score gauge (drives the executive summary)
2. Capability tier health (Digital Customer Experience + Customer Tier
   Experience + the 4
   capability tiers + Payment Networks)
3. Tier health (Bronze / Silver / Gold)
4. Customer geography (RUM page views by country, choropleth)
5. Tier transaction split (api-gateway request mix)
6. Decline rate by tier (1h trend)
7. Auth p99 latency by tier (1h trend)
8. Chaos / Notable Events table (last 4h, severity-coloured)
9. L3 microservice health (auth fan-out)

## 5. Splunk Observability -> ITSI alert bridge

The existing detectors in `terraform/observability.tf` are reused, no need
to re-author. The bridge is **opt-in** because it has to widen the Splunk
Enterprise security group to accept HEC traffic from Splunk Observability's
public egress IPs.

### 5.1 Enable

In your Terraform variables (or `terraform.tfvars` / `TF_VAR_*` env):

```hcl
itsi_alert_bridge_enabled = true

splunk_observability_egress_cidrs = [
  # eu0 region examples - replace with the live list from the docs:
  # https://docs.splunk.com/observability/en/admin/notif-services/about-egress.html
  "3.248.59.20/32",
  "3.249.21.117/32",
  "52.31.69.49/32",
]
```

Then:

```bash
terraform -chdir=terraform apply
```

What this does:

1. Adds an inbound SG rule on 8088 from the o11y CIDRs only.
2. Creates a `signalfx_webhook_integration` named "[NatWest demo] ITSI alert bridge".
3. Appends `Webhook,<integration_id>` to every detector's notification list
   so they all post to HEC when they fire.

### 5.2 Land the correlation search

```bash
scripts/07-itsi-bootstrap.sh
```

The bootstrap script installs every `*.json` file in
`itsi/correlation-searches/` as an ITSI-event-generator saved search.

| File                                                 | What it watches                                                  | Source field on the notable    |
|------------------------------------------------------|-------------------------------------------------------------------|--------------------------------|
| `o11y_to_itsi.json`                                  | Splunk Observability detector firings forwarded via HEC          | `Splunk Observability Cloud`   |
| `payments_excessive_declines_by_tier.json`           | `index=nwpay_audit` payment audits when >20 declines / 5m / tier | `Splunk ES - payments audit`   |
| `payments_madrid_latency_breach.json`                | `index=otel_traces` Madrid p95 > 1500 ms over a 5 min window     | `Splunk ES - payments OTel`    |
| `payments_api_gateway_5xx_breach.json`               | `index=otel_traces` api-gateway 5xx rate >= 5% over a 5 min window | `Splunk ES - payments OTel`  |
| `payments_service_latency_slo_breach.json`           | `index=otel_traces` per-service p99 over 2x the SLO declared in the service tree | `Splunk ES - payments OTel` |
| `payments_ledger_jdbc_errors.json`                   | `index=main` ledger-service stdout, >=20 JDBC/JPA errors / 5m    | `Splunk ES - payments OTel`    |
| `payments_settlement_consumer_idle.json`             | `index=otel_traces` settlement-service span count < 3 over 5 min (steady-state ~40) | `Splunk ES - payments OTel` |
| `chaos_injection_audit.json`                         | `index=nwpay_audit` ANY chaos inject/clear (one notable per call) | `Splunk ES - chaos audit`     |
| `chaos_off_change_window.json`                       | `index=nwpay_audit` chaos injections outside Mon-Fri 09:00-17:00 | `Splunk ES - chaos audit`      |
| `spa_network_connection_changed.json`                | `index=nwpay_audit event_type=network` browser-side connectivity flip | `Splunk ES - SPA network audit` |

`chaos_injection_audit.json` is the **Event-Analytics feed for chaos**: it
fires one notable per `nwpay:chaos` event (severity=high on inject,
severity=info on clear) and maps `target_service` -> the right L2 in the
service tree, so tier-throttle on Bronze shows as an episode on "Bronze
Tier Experience", `db-slow` on "Ledger & Settlement Services",
`madrid-network-degradation` on "Payments by Location", etc. Whenever the
SPA Chaos Dashboard or `scripts/incident.sh` injects something, an
audience watching Episode Review sees a new row appear within ~60 s.

`chaos_off_change_window.json` is the **compliance overlay**: it ALSO
emits a notable, but only when the inject lands outside the change
window. Both notables roll into the same Episode (`service` correlation,
10-minute window) so Episode Review shows ONE ticket with two attached
events: 'chaos was injected' + 'chaos was injected OFF-WINDOW'. That
dual signal is deliberate - the compliance story benefits from seeing
both detections side by side.

Severity mapping (used by `o11y_to_itsi.json`):

| Splunk Observability severity | ITSI severity   |
|-------------------------------|-----------------|
| Critical                      | 6 (critical)    |
| High / Major                  | 5 (high)        |
| Warning                       | 4 (medium)      |
| Minor                         | 3 (low)         |
| Info                          | 2 (normal)      |

The new SIEM-style searches deliberately pick the same `service` taxonomy
("Bronze Tier Experience", "Payment Networks", ...) so every notable
event rolls up onto an existing L2 service node in the tree. They also
emit a `cohort_key` (e.g. `declines:bronze:202605110934`) so repeated
firings inside the same 5-minute window dedupe into a single Episode
rather than 10 noisy tickets.

All notable streams are then grouped into one Episode per service
per 30 minutes by `itsi/aggregation-policies/payments_episode_policy.json`
(also auto-installed by the bootstrap). Episode Review shows ONE ticket
with the APM detector + SIEM banking notable + SIEM chaos notable +
SIEM symptom-detection notable + SPA network notable attached — instead
of multiple independent tickets that the on-call has to correlate by hand.

### 5.2.1 Chaos scenario -> ITSI notable coverage matrix

Every chaos scenario MUST surface at least two independent notables in
Episode Review: the `chaos_injection_audit` (SIEM-side "this is what we
did") plus at least one symptom-detection notable (SIEM/APM-side "this
is what Splunk saw"). The matrix is enforced by the live searches above.

| Chaos scenario              | Audit notable             | Symptom-detection notable(s)                                                  |
|-----------------------------|---------------------------|-------------------------------------------------------------------------------|
| `bad-deploy-fraud`          | chaos_injection_audit ✓   | o11y_to_itsi (SWIFT error rate detector) ✓                                    |
| `swift-counterparty-flap`   | chaos_injection_audit ✓   | o11y_to_itsi (SWIFT error rate detector) ✓                                    |
| `swift-scheme-outage`       | chaos_injection_audit ✓   | o11y_to_itsi (SWIFT error rate detector) ✓                                    |
| `settlement-producer-off`   | chaos_injection_audit ✓   | payments_settlement_consumer_idle ✓                                            |
| `sanctions-cache-disabled`  | chaos_injection_audit ✓   | o11y_to_itsi (sanctions cache miss detector) + payments_service_latency_slo ✓ |
| `db-slow`                   | chaos_injection_audit ✓   | payments_service_latency_slo (ledger SLO breach) + payments_ledger_jdbc_errors when pool saturates ✓ |
| `fraud-cpu-regression`      | chaos_injection_audit ✓   | payments_service_latency_slo (fraud SLO breach) ✓                              |
| `tail-latency-storm`        | chaos_injection_audit ✓   | payments_service_latency_slo (payment-validation SLO breach) ✓                 |
| `latency-creep`             | chaos_injection_audit ✓   | payments_service_latency_slo (payment-status SLO breach) ✓                     |
| `gateway-timeout-squeeze`   | chaos_injection_audit ✓   | payments_api_gateway_5xx_breach ✓                                              |
| `madrid-network-degradation`| chaos_injection_audit ✓   | payments_madrid_latency_breach + o11y_to_itsi (Madrid p95 detector) ✓          |
| `tier-throttle`             | chaos_injection_audit ✓   | payments_excessive_declines_by_tier + o11y_to_itsi (per-tier decline detector) ✓ |
| `cache-cold`                | chaos_injection_audit ✓   | o11y_to_itsi (sanctions cache miss detector) + payments_service_latency_slo ✓ |
| `gold-fast-path-off`        | chaos_injection_audit ✓   | (low severity; chaos audit is the demo signal — gold/silver/bronze trend on RUM tells the story) |
| `kill-service`              | chaos_injection_audit ✓   | payments_api_gateway_5xx_breach (downstream 5xx cascade) ✓                     |
| `pod-restart-gateway`       | chaos_injection_audit ✓   | (transient; chaos audit is the demo signal — RUM page-error blip)              |
| `postgres-outage`           | chaos_injection_audit ✓   | payments_ledger_jdbc_errors + payments_api_gateway_5xx_breach ✓                |
| `redis-outage`              | chaos_injection_audit ✓   | payments_api_gateway_5xx_breach (sanctions/fraud cache misses cascade) ✓       |
| `kafka-outage`              | chaos_injection_audit ✓   | payments_settlement_consumer_idle ✓                                            |
| `payment-meltdown` (story)  | chaos_injection_audit per phase ✓ | inherits db-slow + postgres-outage coverage ✓                            |

When adding a new chaos scenario to `chaos-controller/app/scenarios.py`,
verify both columns map to existing artefacts before merging. If a new
symptom isn't covered by an existing correlation search, add a new
`itsi/correlation-searches/<name>.json` and update this matrix +
`payments_episode_policy.json` filter (if the new `source` value differs).

### 5.3 End-to-end smoke test

Trigger any of the existing chaos scenarios:

```bash
scripts/incident.sh swift-counterparty-flap
```

Expected within ~3 minutes:

1. Splunk Observability detector "[NatWest demo] SWIFT error rate" fires.
2. HEC ingests one event in `index=main sourcetype="splunk_observability:alert"`.
3. The correlation search materialises one notable event.
4. ITSI Episode Review shows the event with severity=Critical,
   service=Payment Networks (SWIFT scheme rolls up via routing-service).
5. Glass-table "Chaos / Notable Events timeline" panel updates.
6. L1 health score on the glass-table drops because Payment Networks ->
   Payment Services -> API Gateway each propagate the critical state up
   the new capability tree.

## 6. Demo flow alignment (what the tree lights up)

Mapping `scripts/incident.sh` scenarios onto the tree (see plan section 6):

| Scenario                          | Service that turns red                                         | Which KPI                                |
|-----------------------------------|----------------------------------------------------------------|------------------------------------------|
| `bad-deploy-fraud`                | fraud-detection-service -> Business Services -> API Gateway    | `Gateway error rate`                     |
| `swift-counterparty-flap`         | swift-network -> Payment Networks -> Payment Services          | `Network error rate` (per-scheme)        |
| `cache-cold`                      | sanctions-aml-service -> Business Services                     | `Sanctions cache miss`                   |
| `db-slow`                         | ledger-service -> Ledger & Settlement Services -> API Gateway  | `Ledger p99 latency`, `Ledger error rate`|
| `fraud-cpu-regression`            | fraud-detection-service -> Business Services                   | `Payment p99 latency` (downstream)       |
| `inject-tier-throttle bronze`     | **Bronze Tier Experience** (Silver/Gold green)                 | `Bronze decline rate`                    |

The Bronze isolation is the headline glass-table moment. It works because
the tier services use `severity_aggregation=max` and reference KPIs filtered
by `customer.tier`, so a 6% Bronze decline rate flips Bronze critical while
the umbrella API Gateway service remains weighted-average green.

## 8. L4 infrastructure KPIs (Redis / Postgres / Kafka)

Drives the *infrastructure* swimlane of the service tree. Each L4 stub is
now a real health-bearing service that propagates upward to the matching
L3 microservice (e.g. Redis -> sanctions-aml-service / fraud-detection-service)
and ultimately to L2 / L1.

### Data flow

```
helm/natwest-payments
  ├─ redis pod          ─┐    sidecar: oliver006/redis_exporter:9121
  ├─ postgres pod       ─┤    sidecar: prometheuscommunity/postgres-exporter:9187
  └─ kafka pod          ─┘    sidecar: bitnami/jmx-exporter:5556 (scrapes broker JMX :5555)

splunk-otel-collector (DaemonSet)
  ├─ receivers.redis        -> redis.* metrics
  ├─ receivers.postgresql   -> postgresql.* metrics  (auth: postgres-monitoring secret)
  ├─ receivers.kafkametrics -> kafka.* metrics
  └─ receivers.prometheus/infra -> redis_*, pg_*, kafka_server_* metrics
       │
       └─► splunk_hec/platform_metrics ──► Splunk Enterprise index=main sourcetype="otel:metrics"
              consumed by kbs_redis_health / kbs_postgres_health / kbs_kafka_health

helm/natwest-payments/templates/infra-heartbeat-cronjob.yaml
  └─ CronJob (every 60s) emits one OTLP span per service.name {redis,postgres,kafka}
     turning the inferred db/queue icons in the o11y APM service map into
     first-class service nodes (Logs + Related Content tabs).
```

### KPIs created on each L4

| Service           | KPI                              | Threshold (warning / critical)        |
|-------------------|----------------------------------|---------------------------------------|
| nwpay_l4_redis    | Redis evictions / min            | 25 / 100                              |
| nwpay_l4_redis    | Redis memory used (bytes)        | 96 MB / 120 MB (maxmemory=128 MB)     |
| nwpay_l4_redis    | Redis connected clients          | informational                         |
| nwpay_l4_postgres | Ledger JDBC pool in use           | 10 / 14 (pool max 16; chaos-gated)    |
| nwpay_l4_postgres | Ledger JDBC pool pending          | 1 / 2 (chaos-gated)                   |
| nwpay_l4_postgres | Ledger JDBC connection timeouts / min | 1 / 5 (chaos-gated)               |
| nwpay_l4_postgres | Postgres backends online          | crit_low 1 / warn_low 1 (chaos-gated) |
| nwpay_l4_kafka    | Kafka brokers online             | warn_low 1 / crit_low 1               |
| nwpay_l4_kafka    | Kafka active controllers         | warn_low 1 / crit_low 1               |
| nwpay_l4_kafka    | Kafka offline partitions         | 0 (warn) / 1 (crit)                   |
| nwpay_l4_kafka    | Kafka under-replicated parts     | 0 (warn) / 1 (crit)                   |
| nwpay_l4_kafka    | Kafka ISR shrinks / min          | 1 / 5                                 |
| nwpay_l4_kafka    | Kafka consumer lag               | 250 / 1000                            |
| nwpay_l4_kafka    | Kafka request p99 latency        | 100 ms / 200 ms                       |
| nwpay_l4_kafka    | Kafka messages-in / sec          | informational                         |
| nwpay_l4_kafka    | Kafka bytes-in / sec             | informational                         |

### Demoing the Kafka KPIs

`scripts/incident.sh kafka-broker-down` force-deletes the kafka pod
(grace period 0) to simulate an unplanned broker outage. While the
broker is down (~30-60s before the Deployment controller's new pod is
Ready):

* `brokers_online` and `active_controller_count` both drop to 0
* `offline_partitions` spikes
* `kbs_kafka_lag` starts growing as settlement-service can't drain
  payments.settled
* `nwpay_l4_kafka` rolls Critical via the weighted_avg aggregation

Once the new pod is Ready the command emits a matching `clear` audit
event so Episode Review shows a clean inject/clear pair, and the KPIs
auto-clear inside one or two `| mstats` bins.

### Provisioning the monitoring credential

`scripts/00-provision.sh` mints a 32-char-hex password for the read-only
`payments_exporter` Postgres role on first run, persists it in `.env`, and
replicates a `postgres-monitoring` Secret into both the `natwest` and
`splunk-otel` namespaces (the chart's postgres_exporter sidecar reads
the Secret via `envFrom`; the collector's postgresql receiver reads it
via `extraEnvVars` -> `secretKeyRef`). Re-runs reuse the existing value.

### Validation

```bash
scripts/lib/itsi_data_probe.sh
```

The probe now reports OK/WARN for `Redis evicted keys`,
`Postgres backends`, and `Kafka brokers` in addition to the application
sources. WARN on any of those means the chart did not roll out the
exporter sidecars or the collector hasn't been helm-upgraded onto the
new `metrics/infra` pipeline yet.

## 9. Maintenance

- All edits live in `itsi/service-tree.yaml`. The bootstrap script is the
  only thing that talks to ITSI's REST API.
- Adding a microservice: append to the `microservices:` list. The script
  generates the L3 service + entity + standard p99/error-rate KPIs.
- Adding a KPI base search: append under `kpi_base_searches:`, then reference
  it by id from a service's `kpis:` list.
- Drift detection: run `scripts/07-itsi-bootstrap.sh --dry-run` and diff the
  output against a saved snapshot.

## 10. Troubleshooting: "Event Analytics shows no episodes"

If the **correlation searches are firing** (you can see notables in
`index=itsi_tracked_alerts`) but the **Episode Review / Event Analytics
screen stays empty**, the failure is in the *grouping* layer, not the
detection layer. Two real-world breakages we've hit and codified:

### 10.1 Java is not installed on the Splunk host

The NEAP grouper is a **Java process** spawned by the `itsi_queue_re_init.py`
modular input (`com.splunk.itsi.search.chunk.RulesEngineSearch`). Without
Java, the process never starts, no policies are loaded, and **no
episodes are ever created** - silently, with the only signal being:

```
$ sudo tail /opt/splunk/var/log/splunk/itsi_queue_re_init.log
... ERROR Java version 8.x - 11.x or Java 17 is required in order to start the Rules Engine.
```

**Fix (already codified):**
- New AL2023 boxes get `java-17-amazon-corretto-headless` installed
  directly from `terraform/cloud-init/splunk-enterprise.tftpl`, and
  `JAVA_HOME=/usr/lib/jvm/java-17-amazon-corretto.x86_64` is appended to
  `/opt/splunk/etc/splunk-launch.conf` so the systemd unit inherits it.
- Already-running boxes self-heal on the next `scripts/00b-update-splunk-config.sh`
  run - step `[00b/java]` is idempotent and only acts when `java` is
  missing or `JAVA_HOME` isn't in `splunk-launch.conf`.

To verify a healthy install:

```bash
ssh -i terraform/splunk-enterprise.pem ec2-user@<splunk-ip>
java -version                                                              # 17.0.x
curl -sk -u admin:'***' \
  'https://127.0.0.1:8089/servicesNS/nobody/SA-ITOA/metric_ad/jvm?output_mode=json'
# expect: "active": "JAVA_HOME", "activeRunnable": true, "version": "17.0"
ps -ef | grep RulesEngineSearch | grep -v grep                             # two java procs
```

### 10.2 NEAP `split_by_field` MUST be a JSON string, not an array

The Splunk ITSI UI stores `split_by_field` as a *string* (e.g. `"service"`),
but the Python `solnlib` REST helpers and some ITSI sample policies use
a single-element JSON array (`["service"]`). The Python side accepts
both; the **Java rules engine only accepts a string** and aborts the
*entire policy queue load* with:

```
ERROR KVStorePolicyFetcher: Cannot deserialize value of type
`java.lang.String` from Array value (token `JsonToken.START_ARRAY`)
... Policy["split_by_field"]
ERROR PolicyManager: Failed to get policies from collection:
       itsi_notable_event_aggregation_policy
```

When this fires, *no* policies match (not even the OOTB `Default Policy`),
so `index=itsi_grouped_alerts` and `itsi_notable_event_group` KV stay
empty even though `itsi_tracked_alerts` is full.

**Fix (already codified):**
- `itsi/aggregation-policies/payments_episode_policy.json` stores
  `"split_by_field": "service"` (string). Do not regress to an array.
- Verify the live policy reads back correctly:

```bash
curl -sk -u admin:'***' \
  'https://127.0.0.1:8089/servicesNS/nobody/SA-ITOA/event_management_interface/notable_event_aggregation_policy/natwest_payments_episode_policy?output_mode=json' \
  | python3 -c 'import sys, json; print(json.loads(sys.stdin.read()).get("split_by_field"))'
# expect: service  (NOT ['service'])
```

### 10.3 Quick end-to-end sanity probe

```bash
# 1. Notables being produced? (should be >> 0)
| eventcount summarize=false index=itsi_tracked_alerts earliest=-15m | stats sum(count)

# 2. Notables being grouped by our policy? (should be >> 0)
search index=itsi_grouped_alerts earliest=-15m itsi_policy_id=natwest_payments_episode_policy | stats count

# 3. Episodes registered in the KV store? (should be >= 1 active)
curl -sk -u admin:'***' \
  'https://127.0.0.1:8089/servicesNS/nobody/SA-ITOA/event_management_interface/notable_event_group?count=20&output_mode=json' \
  | python3 -c 'import sys, json; j=json.loads(sys.stdin.read()); print(len(j if isinstance(j,list) else j.get("entry",[])))'

# 4. Rules engine alive + no policy load errors in the last minute?
sudo tail -100 /opt/splunk/var/log/splunk/itsi_rules_engine.log | grep -E 'Status=(Completed|Failed)' | tail -3
```
