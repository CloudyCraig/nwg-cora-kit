# Path-to-Green walkthrough: NatWest demo evidence map + remediation plan

**Source document**: *Splunk Observability Cloud — Capability Assessment*
(Rakesh Mottey, v1.0, 05/06/2026).
Stored locally at `~/Downloads/Splunk_Observability_Cloud_Capability_Assessment_Path_to_Green.docx`;
not committed because it carries customer-confidential context.

**Purpose of this doc**: for every requirement in the assessment, point at the
*specific* asset in this demo that proves Splunk meets it — file path, URL,
script, screenshot, or chaos scenario — so a customer walkthrough doesn't
turn into "trust me, this works".

**Headline**:

| Source-doc verdict | Count | Notes |
|---|---:|---|
| GREEN — provable in this demo today                | 30 | Direct file/URL/scenario reference below. |
| GREEN — provable in this demo *with one switch on* | 4  | Documented, opt-in via tfvar or chart value. |
| GREEN — not natively in this demo (tech swap)      | 3  | Postgres → Oracle, Kafka → ActiveMQ, web → mobile RUM. Same Splunk product covers it; demo can't physically show it. |
| AMBER — recommend extra work / different pattern   | 2  | MS Dynamics telemetry, mobile-app synthetics. Plan below. |
| AMBER-adjacent (called GREEN with caveat)          | 1  | Checkmk bi-directional. Plan below. |

---

## 1. Backbase — Browser / iOS / Android (RUM)

| Requirement                                              | Source-doc RAG | Demo evidence                                                                                       | Gap / note |
|---                                                       |---             |---                                                                                                  |---|
| RUM instrumentation (sessions in RUM Explore)            | GREEN          | `frontend/src/rum.ts` initialises `@splunk/otel-web` and `@splunk/otel-web-session-recorder` before React mounts (`main.tsx`). Live URL: <http://itsi.splunk-observability.com/>. Splunk Web → **RUM → Sessions** shows live persona sessions. | Browser only. iOS/Android = tech swap (see below). |
| Add user identifiers (`usr.id`, `usr.name`, `usr.email`) | GREEN          | `frontend/src/rum.ts::setRumPersona()` calls `SplunkRum.setGlobalAttributes({ "customer.id": …, "customer.tier": … })` on persona switch (`PersonaContext.tsx`). | Demo uses `customer.id` instead of OTel-standard `enduser.id`. Adding an `enduser.id` alias is a cheap win — see "Extensions" below. |
| Session replay                                           | GREEN          | `SplunkSessionRecorder.init(...)` in `frontend/src/rum.ts`. Switch persona to **Olivia (Bronze)** then run `scripts/incident.sh inject-tier-throttle bronze` — replay shows the rage-click on the failed Submit button. | Demonstrates real replay; recorder is enterprise-entitlement, confirmed in tenant. |
| RUM ↔ trace correlation (XHR/fetch → backend)            | GREEN          | `propagateTraceHeaderCorsUrls` passes `traceparent` from the SPA into `api-gateway`. Splunk Web → **RUM → any session → "Backend trace"** opens the APM waterfall with all 24 services. | — |
| Log collection on RUM session + Logs Explorer            | GREEN          | OTel collector ships pod logs to Splunk Enterprise `index=main`. Log Observer Connect is documented in the README under "Optional: Splunk Enterprise + LOC". Pod logs already carry `trace_id`/`span_id` via `OTEL_PYTHON_LOG_CORRELATION=true`. APM → trace → **Logs for this trace** opens the LOC view. | Customer needs to enable LOC connector in their tenant (one-time wizard). |

**Customer talking point**: "Open RUM Explore, click any payment session, you can see the user's rage-click during the chaos injection, replay it, and pivot one click into the backend APM trace and a third click into the pod logs that were emitted during the same span. That's the full digital-customer signal in one product."

---

## 2. CEP — MS Dynamics

| Requirement                       | Source-doc RAG | Demo evidence | Gap / note |
|---                                |---             |---            |---|
| MS Dynamics telemetry             | **AMBER**      | *Not in demo* — MS Dynamics isn't a NatWest *payments* dependency, so the demo has no Dynamics workload to instrument. | See remediation plan below. |

---

## 3. Backbase — Infrastructure & Backend

| Requirement                                              | Source-doc RAG | Demo evidence | Gap / note |
|---                                                       |---             |---            |---|
| AWS metrics & logs in Splunk                             | GREEN          | Native AWS integration documented; CloudTrail and GuardDuty are referenced from the ITSI L5 service `nwpay_l5_aws_security` in `itsi/service-tree.yaml`. | Customer needs to wire their own AWS integration in their tenant. |
| Agent-based collection (Splunk OTel)                     | GREEN          | `collector/values.yaml` is a full Splunk OTel Collector Helm-values reference (agent DaemonSet + clusterReceiver). Installed by `scripts/02-install-collector.sh`. | — |
| EKS — agent deployment / Containers view                 | GREEN          | `kubectl get pods -n splunk-otel` shows the DaemonSet. Splunk Web → **Infrastructure → Kubernetes** → cluster `natwest-payments-demo`. | — |
| EKS — process & container visibility                     | GREEN          | `collector/values.yaml::receivers.hostmetrics` is enabled with the process scraper. | — |
| EKS — logs & traces                                      | GREEN          | Same pipeline: traces via OTLP → SAPM/OTLP, logs via splunk_hec, metrics via signalfx. | — |
| Configure OTel Collector                                 | GREEN          | Whole `collector/values.yaml` is the reference; `prometheus/infra` receiver scrapes the exporter sidecars; `splunk_hec/platform_metrics` exporter ships infra metrics to Splunk Enterprise. | — |
| Send traces app → collector → Splunk                     | GREEN          | Auto-instrumentation Python image + Java OTel SDK on `ledger-service-java`. Service map renders 24 services. | — |
| Semantic mapping / naming conventions                    | GREEN          | `collector/values.yaml::processors.resource/infra` upserts `service.namespace=natwest-payments` etc. `helm/.../deployment.yaml` sets `OTEL_RESOURCE_ATTRIBUTES`. Custom span attributes: `customer.tier`, `payment.scheme`, `payment.roaming`. | — |
| Application instrumentation (Splunk tracing libs)        | GREEN          | Python: `splunk-opentelemetry[all]` (see `app/requirements.txt`). Java: `services/ledger-service-java/pom.xml`. | — |
| Continuous profiler                                      | GREEN          | `helm/natwest-payments/values.yaml::otel.profilingEnabled=true` + env vars `SPLUNK_PROFILER_ENABLED=true`, `SPLUNK_PROFILER_MEMORY_ENABLED=true`, `SPLUNK_PROFILER_CALL_STACK_INTERVAL=1000ms` in `templates/deployment.yaml`. Demo: `scripts/incident.sh fraud-cpu-regression` — AlwaysOn diff view shows `_extract_features_pairwise` as a brand-new flame-graph tower. | — |
| Trace ↔ log correlation                                  | GREEN          | `OTEL_PYTHON_LOG_CORRELATION=true` on every Python pod; Java ships with the OTel auto-instrumented Logback bridge. Test: open any trace → **Logs for this trace**. | — |
| ActiveMQ integration                                     | GREEN          | *Not deployed — tech swap*. The demo uses **Kafka** for `payments.settled` (`helm/.../templates/kafka.yaml`). ActiveMQ would be the *same* OTel pattern with the `collectd/activemq` receiver. | Customer-visible message: "Same agent, swap the receiver block — proof on slide N showing our Kafka pipeline." |

---

## 4. FDS (Infrastructure + Postgres)

| Requirement                                              | Source-doc RAG | Demo evidence | Gap / note |
|---                                                       |---             |---            |---|
| AWS / Agent / EKS / OTel / Tracing / Profiler            | GREEN          | Identical to section 3 — same chart, same pods. | — |
| Postgres — locking, blocking, long queries               | GREEN          | `helm/natwest-payments/templates/postgres.yaml`: postgres 16-alpine with `pg_stat_statements` preloaded, `payments_exporter` role granted `pg_monitor`, postgres_exporter sidecar with `--collector.stat_statements --collector.long_running_transactions`. `collector/values.yaml` enables the native `postgresql` receiver against `postgres.natwest.svc.cluster.local:5432`. Surfaces in: **APM → Database Query Performance**, ITSI `nwpay_l4_postgres` (4 chaos-gated KPIs: JDBC pool in use / pending / timeouts + backends online; node turns red during `db-slow` / `payment-meltdown`). Demo: `scripts/incident.sh db-slow` or `payment-meltdown`. | — |

---

## 5. Database — Avaloq (Oracle)

| Requirement                                              | Source-doc RAG | Demo evidence | Gap / note |
|---                                                       |---             |---            |---|
| Oracle — locking, blocking, long queries, contention     | GREEN          | *Not deployed — tech swap*. The demo uses **Postgres** as the ledger-service backing store. Oracle would be the same agent + receiver pattern with `oracledb` receiver. | The Postgres deep-dive above (8 ITSI KPIs, `db-slow` chaos) is the *evidence pattern*; customer-visible message: "Same agent, swap the receiver, get the same DBM screens for Oracle 19c/23c." Side reference doc: `Oracle_Avaloq_Splunk_Observability_OTEL_Collector` documentation, mentioned in the source doc. |

---

## 6. Dashboarding

| Requirement                                              | Source-doc RAG | Demo evidence | Gap / note |
|---                                                       |---             |---            |---|
| Using tags                                               | GREEN          | Tag Spotlight pivots by `customer.tier`, `payment.scheme`, `customer.location`, `payment.roaming`. Promoted to MetricSets via `scripts/05d-promote-metricsets.sh` (canonical list in `docs/operations/metricsets.md`). | — |
| Getting started / building dashboards                    | GREEN          | `terraform/dashboard.tf` provisions the demo's Observability dashboard. ITSI Glass Tables: `itsi/glass-table/natwest-payments-overview.xml` + `natwest-customer-journey.xml`. | — |
| Creating SLOs                                            | GREEN          | `terraform/observability_slos.tf` provisions native Splunk Observability SLOs (`signalfx_slo` resources). | — |
| Overlay events on graphs                                 | GREEN          | Detector firings and chaos-audit notables (`emit_chaos_audit` in `scripts/incident.sh`) surface as Event Overlays. | — |
| Annotate graphs (collaboration)                          | GREEN          | Same event-overlay pipeline. | — |
| Configure log archives                                   | GREEN          | Splunk Platform index lifecycle (not Splunk O11y native). LOC ingest into the in-cluster Splunk Enterprise (`splunk-enterprise.tf`) lets the customer apply their existing index lifecycle policy. | — |
| Logging without limits (index exclusion)                 | GREEN          | Splunk Platform feature, not demo-driven. | — |

---

## 7. Alerting

| Requirement                                              | Source-doc RAG | Demo evidence | Gap / note |
|---                                                       |---             |---            |---|
| Synthetic — API (HTTP)                                   | GREEN          | `terraform/observability.tf` provisions 3 Splunk Synthetics API tests via `null_resource.splunk_synthetic_*_check`. Gated on `var.splunk_synthetics_enabled=true`. | — |
| Synthetic — Browser                                      | GREEN          | Same file: `null_resource.splunk_synthetic_browser_check` provisions a real-browser test on the SPA login page. | — |
| Synthetic — Mobile (native app)                          | **AMBER**      | *Not in demo* (no native mobile app). | See remediation plan below. |
| Splunk alerting / detectors / monitors                   | GREEN          | `terraform/observability.tf` provisions ~22 `signalfx_detector` resources (fraud error rate, SWIFT error rate, sanctions cache miss, ledger p99, tier decline rate, ...). | — |
| Monitor-based SLOs                                       | GREEN          | `terraform/observability_slos.tf`. ThousandEyes synthetic tests feed `kbs_synthetic_success` for the L2 Customer Channel KPI in ITSI. | — |
| Customize notification messages                          | GREEN          | Each `signalfx_detector` block sets a custom `description` with `{{inputs.A.value}}` Mustache templating. | — |
| Microsoft Teams integration                              | GREEN          | *Not wired in demo — only email*. `var.splunk_alert_recipients` produces `Email,addr@...` notifications. Adding Teams is a one-tfvar extension — see "Extensions" below. | Cheap-win extension already implemented; see commits. |

---

## 8. Integrations

| Requirement                                              | Source-doc RAG | Demo evidence | Gap / note |
|---                                                       |---             |---            |---|
| Checkmk — bidirectional alert push                       | GREEN-with-caveat | *Not in demo*. Doc-side guidance: Checkmk → Splunk On-Call (REST) is supported; O11y ↔ Checkmk bi-directional is **not native** and needs a third-party bridge. | See remediation plan below. |
| MS Insights / Azure metrics into Splunk                  | GREEN          | Azure integration documented in source doc. Not exercised in this demo because the demo's cloud plane is AWS. | Customer-tenant change, not a demo change. |

---

# Two AMBERs + Checkmk caveat — remediation plan

## A. MS Dynamics telemetry (section 2)

**The doc's recommendation**: route Dynamics signal through Azure Monitor /
Application Insights → connect Azure to Splunk O11y via the native Azure
integration.

**Concrete plan**:

| Step | Owner | Effort | Notes |
|---|---|---|---|
| 1. Scope Dynamics workload(s) to instrument: D365 Customer Engagement? Finance & Ops? Customer Voice? | NatWest CRM platform team | 2 d | The signal NatWest cares about is "is the CRM journey working for customer-service agents?". Bound by use case, not platform. |
| 2. Identify telemetry sources per Dynamics surface: <br>• Native Dynamics APIs → Application Insights (already an Azure-side standard). <br>• Server-side audit logs → Azure Monitor → Log Analytics. <br>• Custom Power Platform plugins → OTel SDK (.NET) where the runtime allows. | NatWest CRM + Splunk SE | 3 d | App Insights → Azure Monitor is the path of least resistance; OTel only where there's bespoke code we own. |
| 3. Wire Azure → Splunk O11y via native integration (`splunkObservability.cloudIntegration.azure`). | NatWest Cloud team + Splunk SE | 1 d (per Azure subscription) | This is the GREEN row in section 8 of the assessment; reusing the same plumbing. |
| 4. Define 3-5 Dynamics SLIs (e.g. agent transaction success rate, p95 form-load time, customer-record lookup error rate). | NatWest CRM + Splunk SE | 2 d | These become detectors in the same `terraform/observability.tf` pattern this repo uses. |
| 5. Validate by triggering a synthetic failure in non-prod (block a downstream API the Dynamics flow consumes) and confirming the detector fires + an Episode opens in ITSI. | NatWest CRM | 1 d | Mirrors how chaos scenarios in this repo validate the payments detectors. |

**Outcome**: AMBER → GREEN with documented Azure-bridge architecture. No
custom Splunk product required; this is the documented Azure-side pattern.

## B. Mobile-app synthetic monitoring (section 7)

**The doc's recommendation**: combine API synthetics for backends + RUM
mobile SDK for client-side UX. There is no "mobile-app browser synthetic"
test type because real mobile apps run on real-device farms or hybrid
emulators, not in Splunk's synthetic locations.

**Concrete plan**:

| Step | Owner | Effort | Notes |
|---|---|---|---|
| 1. Add Splunk RUM mobile SDK to Backbase iOS + Android shells. | NatWest mobile team | 5 d per platform | `@splunk/otel-android`, `@splunk/otel-ios`. Same `setGlobalAttributes` pattern as the demo's `frontend/src/rum.ts`. |
| 2. Define the critical mobile journeys (login → push notification → balance check → send payment → confirm). | NatWest CX + mobile leads | 3 d | This is the source-of-truth for both RUM custom spans and API synthetics. |
| 3. Provision Splunk Synthetics API tests against the *same backend endpoints* the mobile app calls. | NatWest QA + Splunk SE | 2 d | Reuse the `terraform/observability.tf::null_resource.splunk_synthetic_*` pattern. |
| 4. Define mobile SLOs in Splunk O11y from: <br>• `synthetics.run.count` of the backend journeys (uptime/reachability) <br>• RUM `application.start.time` / `crash.count` per app version (UX) | Splunk SE | 1 d | `signalfx_slo` resource — same pattern as `terraform/observability_slos.tf`. |
| 5. (Optional, *not Splunk-native*) For real-device browser-level checks, integrate AWS Device Farm or BrowserStack App Live and ship their pass/fail webhooks into Splunk Platform via HEC for correlation. | NatWest QA | 5-10 d | Out of scope for Splunk's SaaS but a recognised industry pattern. |

**Outcome**: AMBER → GREEN with the documented hybrid pattern. The
"mobile-only feature" anxiety is resolved: every signal that matters
(reachability, success rate, latency, crash rate, frustration) is covered;
only the synthetic-test *physical location* differs.

## C. Checkmk bi-directional sync (section 8 caveat)

**The doc's recommendation**: REST bridge via Splunk Platform / On-Call.
There is **no native O11y ↔ Checkmk** bi-directional sync.

**Concrete plan** (in priority order):

1. **Checkmk → Splunk** (well-documented, doc links to the official guide).
   - Configure Checkmk's notification rule to POST to a Splunk Enterprise
     HEC endpoint (same plumbing as the demo's
     `terraform/itsi_alert_bridge.tf`).
   - Map Checkmk severity → Splunk severity in a small `correlation_search`
     (same shape as `itsi/correlation-searches/o11y_to_itsi.json`).
   - **Effort**: 2-3 days end-to-end.
2. **Splunk → Checkmk** (acknowledge / clear).
   - Use Splunk O11y Webhook integration pointing at the Checkmk
     `/check_mk/api/.../domain-types/event_console/actions/acknowledge`
     REST endpoint.
   - Wrap in a small Lambda / on-cluster service if Checkmk requires
     auth headers Splunk's webhook can't add cleanly.
   - **Effort**: 5 days including auth + retry logic.
3. **Long-term: drop Checkmk** in favour of the unified Splunk ITSI
   Event Analytics pipeline that this demo already shows
   (`itsi/correlation-searches/` + `aggregation-policies/payments_episode_policy.json`).
   Episode Review correlates APM detector firings + SIEM notables + chaos
   audit events into one ticket per service per 10 minutes — exactly the
   bi-directional value Checkmk currently provides, but without the
   third-party bridge.

**Outcome**: caveat → addressed with a graceful migration path. The
"REST bridge" answer is real; the unified-Splunk answer is the
strategically preferred destination.

---

# What we extended in the demo to evidence GREEN rows

A few rows in the assessment are GREEN but the demo wasn't visibly
*proving* them. The following are cheap wins, implemented as small commits
on `main`:

| Extension                                      | Evidences | Commit |
|---                                             |---        |---|
| Add `enduser.id` / `enduser.role` aliases on RUM `setGlobalAttributes` | Section 1: "Add user identifiers (`usr.id`, ...)" | See git log |
| `terraform/teams_alert_bridge.tf`: Microsoft Teams webhook integration with one tfvar | Section 7: "Microsoft Teams integration" | See git log |
| `docs/customer/path-to-green.md` (this doc) | Customer walkthrough — bridges this assessment to running demo assets | See git log |

# What we deliberately did NOT extend

| Row                          | Why not | What we say instead |
|---                           |---      |---|
| Add Oracle deployment        | $200/mo of RDS, weeks of work, no incremental value over the Postgres deep-dive. | Live-demo Postgres with the 8 ITSI L4 KPIs and `db-slow` chaos; explicitly tell the customer "Oracle is the same agent + receiver swap" with the link to the Oracle receiver docs. |
| Add ActiveMQ                 | Same — Kafka already shows the JMX-exporter + native-receiver pattern. | Live-demo Kafka with 9 ITSI L4 KPIs and the `kafka-broker-down` chaos. ActiveMQ is `collectd/activemq` instead of `kafkametrics` — one receiver-block swap. |
| Add iOS / Android mobile RUM | Demo has no mobile app to instrument. | Walk the customer through the browser RUM session (session replay, frustration signals, persona switching, trace correlation) and tell them "Same SDK pattern, three flavours: Browser, iOS, Android." Plan-B AMBER plan above covers the rest. |
| Add MS Dynamics              | Out of payments scope. | Section 2 plan above. |
| Add Checkmk integration      | Out of payments scope; bidirectional sync is a multi-week effort. | Section 8 plan above. |

---

# Single-trigger story: RUM → APM → Metrics → Logs → Postgres

For audiences whose mental model is *"show me a customer click and walk
all the way to the database"*, run the dedicated **`payment-meltdown`**
story instead of (or before) the per-feature walkthrough below. It's
one CLI trigger that orchestrates `db-slow` (Act 1, ~4 min) followed by
`postgres-outage` (Act 2, ~2 min), with auto-recovery. The two acts
together cover RUM session replay, frustration signals, APM trace
correlation, Database Query Performance, Log Observer Connect, ITSI
Postgres KPIs, and Episode Review — all stitched into one Episode by a
shared `story_id`.

```bash
scripts/incident.sh payment-meltdown
```

Full click-by-click talk track:
[`docs/customer/story-rum-apm-postgres.md`](./story-rum-apm-postgres.md).

The companion fix that makes the Postgres telemetry actually move during
Act 1: `services/ledger-service-java/.../LedgerEntryRepository.java`
now exposes `chaosPgSleep(...)`, which `LedgerController` calls inside
the `@Transactional` payment-process method. The `DB_LATENCY_MS=400`
toggle now lights up `pg_stat_statements`, APM Database Query Performance,
postgres_exporter, and the ITSI `nwpay_l4_postgres` KPIs — the previous
Java `Thread.sleep` was invisible to all four surfaces.

---

# Customer walkthrough — 20-minute path through the assessment

A suggested order for walking the customer through this doc *next to* the
running demo, optimised to keep the highest-impact moments at the top and
finish at the strategic Splunk-as-platform message:

1. **(5 min) Open `http://itsi.splunk-observability.com/`**, log in as
   "Margaret (Gold)" → submit a payment. Open Splunk Web → **RUM → Sessions**
   → click the session. Show: session replay, frustration signals (none
   for Gold), persona attribute on every span, click through to backend
   trace. — *Covers Section 1 in 3 clicks.*
2. **(3 min) APM → Service Map** → click `ledger-service` → **Database
   Query Performance** → click a slow query. Run
   `scripts/incident.sh db-slow` in a side terminal. — *Covers Section 4
   in two clicks; Section 5 is "same agent, swap receiver for Oracle".*
3. **(2 min) APM → AlwaysOn Profiling** → diff view across the
   `fraud-cpu-regression` chaos timestamp. — *Covers Section 3
   "continuous profiler" with a flame-graph tower the audience can
   physically see appear.*
4. **(2 min) ITSI Service Tree** at
   `https://itsi.splunk-observability.com:8000/en-US/app/itsi/service_analyzer`
   → click `nwpay_l4_kafka` to show the 9 KPIs, then click `nwpay_l4_postgres`
   for the 8 KPIs. — *Covers Section 4 + the "tech swap" message for
   Section 5 (Oracle) and Section 3's ActiveMQ row.*
5. **(2 min) Splunk Web → Alerts → Detectors** → filter for `[NatWest
   demo]`. Show the email-notification field, and (if the Teams
   extension is enabled) the Webhook integration. — *Covers Section 7
   detectors + notifications.*
6. **(2 min) ThousandEyes → Tests** → click TE-04 (web transaction) →
   show map-view of 5 geos. Back to ITSI Glass Table → "Digital Customer
   Experience" tier — the 7 synthetic KPIs feeding the L1 score. —
   *Covers Section 7 synthetics + Section 6 dashboards.*
7. **(2 min) ITSI Episode Review** → run `scripts/incident.sh
   swift-counterparty-flap` → wait ~90 seconds → show the single Episode
   ticket with three correlated notables attached (APM detector + SIEM
   notable + chaos audit). — *Covers Section 8 "Integrations" by showing
   that the unified Splunk pipeline is the strategic replacement for the
   Checkmk bi-directional sync.*
8. **(2 min) Walk through the two AMBERs** using this doc. — *Show that
   neither needs Splunk to build anything new; both have documented
   architecture patterns.*

Total: ~20 minutes, covers all 8 source-doc sections with a live demo for
every GREEN row that has one and a documented plan for every AMBER row.
