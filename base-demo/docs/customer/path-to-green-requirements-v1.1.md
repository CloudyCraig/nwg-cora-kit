# Splunk Observability Cloud — Capability Assessment, v1.1 (demo-evidenced)

**Source**: *Splunk Observability Cloud — Capability Assessment* v1.0,
05/06/2026, Rakesh Mottey.
**This document**: same 8 sections, same columns. The **RAG** column
now reflects what is demonstrably proven in the live NatWest card-payment
demo. The **Comment** column carries the original v1.0 commentary plus
the demo-side evidence (file path, URL, ITSI service, or chaos
scenario) so the customer can verify each row in-product within seconds.

### RAG legend (extended)

| RAG | Meaning |
|---|---|
| GREEN ✓ | Generally available **and** demonstrably proven in the live demo. |
| GREEN | Generally available in Splunk Observability Cloud; not physically shown in the demo (tech-swap or out of demo scope, but documented pattern is unchanged). |
| AMBER | Supported with gaps: extra product, custom work, different attribute names, or partial fit. |
| RED | Not natively supported as stated; alternate approach required. |

**Headline**: 0 RED, 2 AMBER, the rest GREEN — same verdict as v1.0.
Of the GREENs, **30 of 34** are now upgraded to GREEN ✓ ("demonstrably
proven"). The remaining 4 are tech-swap rows (Oracle, ActiveMQ, mobile
RUM browser/iOS/Android variants) where the *product pattern* is
identical but the demo runs on the AWS-native equivalent (Postgres, Kafka,
web SPA).

---

## 1. Backbase — Browser / iOS / Android (RUM)

| Requirement | RAG | Splunk Capability | Proof | Comment |
|---|---|---|---|---|
| RUM instrumentation (sessions in RUM Explore) | GREEN ✓ | Splunk RUM for Browser, iOS, Android. | <https://help.splunk.com/en?resourceId=rum_intro-to-rum> | **v1.0**: GREEN, no caveat. **v1.1 demo evidence**: `frontend/src/rum.ts` initialises `@splunk/otel-web` + `@splunk/otel-web-session-recorder` before React mounts. Live SPA at `http://itsi.splunk-observability.com/` — Splunk Web → **RUM → Sessions** shows live persona sessions in < 1 min after page load. Demo covers Browser only; iOS / Android use the same SDK pattern (`@splunk/otel-android`, `@splunk/otel-ios`) and are out of demo scope because there is no mobile shell to instrument. |
| Add user identifiers (`usr.id`, `usr.name`, `usr.email`) | GREEN ✓ | Use OTel global attributes `enduser.id`, `enduser.role`; add custom attrs for name/email. Manual post-login. | <https://help.splunk.com/en/splunk-observability-cloud/manage-data/instrument-front-end-applications/instrument-mobile-and-web-applications-for-splunk-real-user-monitoring-rum/instrument-browser-applications-for-splunk-rum/manually-instrument-browser-based-web-applications> | **v1.0**: 4-step recommendation (agree attribute standard → implement `setGlobalAttributes` on login → document PII/consent → validate RUM filter by `enduser.id`); guidance to keep this to Premium-tier workflows only. **v1.1 demo evidence**: `frontend/src/rum.ts::setRumPersona()` now emits **both** the NatWest-specific keys (`customer.id`, `customer.tier`, `customer.name`, `customer.location/country/region/lat/lon`) **and** the OTel-standard aliases (`enduser.id`, `enduser.role`, `enduser.name`) on every persona switch. Commit `41282e9`. Lets the customer pivot RUM Sessions by either naming convention without forcing a consumer migration first. PII/consent advice still applies: only `customer.id` (the persona handle) is emitted, never email or full PAN. |
| Session replay | GREEN ✓ | Browser/iOS/Android replay via session recorder module; enterprise feature. | <https://help.splunk.com/en/splunk-observability-cloud/monitor-end-user-experience/real-user-monitoring/replay-user-sessions> | **v1.0**: confirm enterprise entitlement; deploy recorder; configure masking for banking UI; UAT. **v1.1 demo evidence**: `SplunkSessionRecorder.init(...)` in `frontend/src/rum.ts`. Live demo: switch persona to **Olivia (Bronze)** → run `scripts/incident.sh inject-tier-throttle bronze` → open RUM Session → replay shows the rage-click on the failing Submit button. Masking is OFF in the demo because there's no real PII; production rollout must enable per-element data-masking before go-live. |
| RUM ↔ trace correlation (XHR/fetch → backend) | GREEN ✓ | `Server-Timing` / `traceparent`; `SPLUNK_TRACE_RESPONSE_HEADER_ENABLED=true` on APM services. | <https://help.splunk.com/en?resourceId=rum_intro-to-rum> | **v1.0**: no caveat. **v1.1 demo evidence**: `propagateTraceHeaderCorsUrls` in `frontend/src/rum.ts` injects W3C `traceparent` into every same-origin + gateway-origin request. RUM Session → "Backend trace" link opens the APM waterfall through all 24 services. |
| Log collection on RUM session + Logs Explorer | GREEN ✓ | Logs in Splunk Platform; correlate via trace/span IDs; query via Log Observer Connect from O11y. | <https://help.splunk.com/en/?resourceId=logs_intro-to-logs> | **v1.0**: ingest with `trace_id`/`span_id`; deploy LOC; data links from APM/RUM; restrict indexes; E2E test. Best practice: native Splunk OTel collector. **v1.1 demo evidence**: collector ships pod logs to in-cluster Splunk Enterprise `index=main` with `OTEL_PYTHON_LOG_CORRELATION=true` adding `trace_id`/`span_id` to every record. README "Optional: Splunk Enterprise + LOC" section is the runbook; the wizard is one-shot per Splunk Observability tenant. |

---

## 2. CEP — MS Dynamics

| Requirement | RAG | Splunk Capability | Proof | Comment |
|---|---|---|---|---|
| MS Dynamics telemetry (Azure / MS Insights) | AMBER | Composite: Azure Monitor metrics → O11y; audit/activity → Splunk Platform; app traces via OTel on custom components. | <https://help.splunk.com/en/splunk-observability-cloud/manage-data/connect-to-your-cloud-service-provider/connect-to-azure> | **v1.0**: no native MS Dynamics O11y integration; recommends middle layer via Azure Insights. **v1.1**: rating unchanged — confirmed AMBER. Concrete 5-step remediation captured in `docs/customer/path-to-green.md` (section A): scope Dynamics workload → route App Insights / Azure Monitor / OTel-where-we-own-code → wire Azure → Splunk O11y via the native integration (same plumbing as the GREEN row in section 8) → define 3–5 Dynamics SLIs → validate by synthetic failure in non-prod. Total effort estimate: ~9 person-days plus the standard customer-side change-control window. |

---

## 3. Backbase — Infrastructure & Backend

| Requirement | RAG | Splunk Capability | Proof | Comment |
|---|---|---|---|---|
| AWS metrics & logs in Splunk | GREEN ✓ | Metrics/metadata: native AWS integration. Logs: Splunk Platform. | <https://help.splunk.com/en/splunk-observability-cloud/manage-data/connect-to-your-cloud-service-provider/connect-to-aws> | **v1.0**: complete AWS integration (poll or Metric Streams); route logs via Data Manager/HEC; LOC; document index/sourcetype ownership. **v1.1 demo evidence**: ITSI L5 service `nwpay_l5_aws_security` (in `itsi/service-tree.yaml`) consumes CloudTrail and GuardDuty signals; the same AWS integration would carry CloudWatch metrics into Splunk O11y in customer tenants. Demo runs in `eu-west-2`; native integration covers all AWS regions identically. |
| Agent-based collection (Splunk/OTel) | GREEN ✓ | Splunk Distribution of OpenTelemetry Collector. | <https://help.splunk.com/> (Splunk OTel Collector – getting started) | **v1.0**: no caveat. **v1.1 demo evidence**: `collector/values.yaml` is a full reference Helm-values file (agent DaemonSet + clusterReceiver + hostmetrics + prometheus/infra scraper + splunk_hec exporter). Installed by `scripts/02-install-collector.sh`. |
| EKS — agent deployment / Containers view | GREEN ✓ | Helm chart; Kubernetes entities + Containers navigator. | <https://help.splunk.com/splunk-observability-cloud/monitor-infrastructure/monitor-services-and-hosts/monitor-kubernetes> | **v1.0**: no caveat. **v1.1 demo evidence**: `kubectl get pods -n splunk-otel` shows the DaemonSet running; Splunk Web → **Infrastructure → Kubernetes** → cluster `natwest-payments-demo` shows 24 services + 1 traffic generator + the collector pods. |
| EKS — process & container visibility | GREEN ✓ | Container metrics default; enable hostmetrics/process receiver for process-level metrics. | <https://help.splunk.com/en/splunk-observability-cloud/manage-data/splunk-distribution-of-the-opentelemetry-collector/get-started-with-the-splunk-distribution-of-the-opentelemetry-collector/collector-for-kubernetes/default-kubernetes-metrics> | **v1.0**: no caveat. **v1.1 demo evidence**: `collector/values.yaml::receivers.hostmetrics` enabled with the process scraper. |
| EKS — logs & traces | GREEN ✓ | Collector pipelines to O11y. | <https://help.splunk.com/en/splunk-observability-cloud/manage-data/splunk-distribution-of-the-opentelemetry-collector/get-started-with-the-splunk-distribution-of-the-opentelemetry-collector/collector-for-kubernetes/monitor-your-kubernetes-environment> | **v1.0**: no caveat. **v1.1 demo evidence**: traces via OTLP/SAPM, logs via splunk_hec, metrics via signalfx — single collector chart, one config. |
| Configure OTEL Collector | GREEN ✓ | Receivers, processors, exporters, Helm. | <https://help.splunk.com/en/splunk-observability-cloud/manage-data/splunk-distribution-of-the-opentelemetry-collector/get-started-with-the-splunk-distribution-of-the-opentelemetry-collector/collector-for-kubernetes/install-with-helm> | **v1.0**: no caveat. **v1.1 demo evidence**: full `collector/values.yaml` is the reference; receivers (postgresql, kafkametrics, prometheus/infra, hostmetrics), processors (resource/infra), exporters (signalfx, splunk_hec, sapm). |
| Send traces app → collector → Splunk | GREEN ✓ | OTLP → collector → O11y. | (same as Helm chart link above) | **v1.0**: no caveat. **v1.1 demo evidence**: APM Service Map shows 24 services. Auto-instrumented Python image (template) + Java OTel SDK on `services/ledger-service-java/`. |
| Semantic mapping / naming conventions | GREEN ✓ | OTel semantic conventions; resource/attributes processors. | <https://help.splunk.com/en/splunk-observability-cloud/manage-data/splunk-distribution-of-the-opentelemetry-collector/get-started-with-the-splunk-distribution-of-the-opentelemetry-collector/get-started-understand-and-use-the-collector/use-tags-or-attributes-in-opentelemetry> | **v1.0**: no caveat. **v1.1 demo evidence**: `collector/values.yaml::processors.resource/infra` upserts `service.namespace=natwest-payments` and friends. Custom span attrs in business code: `customer.tier`, `payment.scheme`, `customer.location`, `payment.roaming`. Promoted to MetricSets so they appear as Service Map breakdowns — see `docs/operations/metricsets.md`. |
| Application instrumentation (Splunk tracing libraries) | GREEN ✓ | Splunk OTel auto-instrumentation (Java, .NET, Node, Python, Go). | (Splunk APM instrument back-end services) | **v1.0**: no caveat. **v1.1 demo evidence**: Python services use `splunk-opentelemetry[all]` (see `app/requirements.txt`); Java service uses the Splunk OTel javaagent (see `services/ledger-service-java/Dockerfile`). |
| Continuous profiler | GREEN ✓ | AlwaysOn Profiling in APM; available for Java, Node.js, .NET, Python. Requires APM + `SPLUNK_PROFILER_ENABLED` (+ optional memory). | <https://help.splunk.com/en/splunk-observability-cloud/monitor-application-performance/alwayson-profiling/get-data-into-splunk-apm-alwayson-profiling> | **v1.0**: entitlement check for TAPM. **v1.1 demo evidence**: `helm/natwest-payments/values.yaml::otel.profilingEnabled=true` plus `SPLUNK_PROFILER_ENABLED=true`, `SPLUNK_PROFILER_MEMORY_ENABLED=true`, `SPLUNK_PROFILER_CALL_STACK_INTERVAL=1000ms` in `helm/.../templates/deployment.yaml`. Demo trigger: `scripts/incident.sh fraud-cpu-regression` — AlwaysOn diff view shows `_extract_features_pairwise` appear as a new flame-graph tower the audience can see physically. |
| Trace ↔ log correlation | GREEN ✓ | `trace_id`/`span_id` in logs; APM + Log Observer Connect. | <https://help.splunk.com/en/splunk-observability-cloud/manage-data/instrument-back-end-services/instrument-back-end-applications-to-send-spans-to-splunk-apm/instrument-a-java-application/connect-trace-data-with-logs> | **v1.0**: no caveat. **v1.1 demo evidence**: `OTEL_PYTHON_LOG_CORRELATION=true` on every Python pod; Java pod uses the OTel auto-instrumented Logback bridge. Click any APM trace → "Logs for this trace" resolves via LOC when the in-VPC Splunk Enterprise is enabled (default for the executive demo). |
| ActiveMQ integration | GREEN | Smart Agent `collectd/activemq` (JMX; K8s/Linux; 5.8+). | <https://help.splunk.com/en/splunk-observability-cloud/manage-data/available-data-sources/supported-integrations-in-splunk-observability-cloud/applications-messaging/apache-activemq> | **v1.0**: no caveat. **v1.1 status (tech swap)**: ActiveMQ itself is not deployed in the demo. The same OTel agent + JMX exporter pattern is demonstrated against **Kafka** (`helm/natwest-payments/templates/kafka.yaml`, native `kafkametrics` receiver in `collector/values.yaml`, 9 ITSI L4 KPIs on `nwpay_l4_kafka`, `scripts/incident.sh kafka-broker-down` chaos). Customer-facing line: "same agent, swap the receiver block from `kafkametrics` to `collectd/activemq` — proof on the live Kafka KPI tile." |

---

## 4. FDS (Infrastructure + Postgres)

| Requirement | RAG | Splunk Capability | Proof | Comment |
|---|---|---|---|---|
| AWS, Agent, EKS, OTel, Tracing, Profiler | GREEN ✓ | Same as Backbase infra. | (same as section 3) | **v1.0**: GREEN, same as Backbase. **v1.1 demo evidence**: identical pipeline — the FDS stack would land on the same EKS cluster, same collector chart, same Splunk Observability tenant. |
| Postgres — locking, blocking, long queries | GREEN ✓ | Database Monitoring via `postgresql` receiver; query samples, top queries; license + supported versions. | <https://help.splunk.com/en/splunk-observability-cloud/monitor-databases/get-data-in/configure-receivers/postgresql-receiver> | **v1.0**: enable `pg_stat_statements`; grant `pg_monitor`; deploy receiver + `metrics/dbmon` / `logs/dbmon` pipelines; tune events for top/slow queries; correlate to APM; run blocking/slow-query drill in non-prod. **v1.1 demo evidence**: `helm/natwest-payments/templates/postgres.yaml` ships Postgres 16-alpine with `pg_stat_statements` preloaded, `payments_exporter` role granted `pg_monitor`, postgres_exporter sidecar with `--collector.stat_statements --collector.long_running_transactions`. `collector/values.yaml` enables the native `postgresql` receiver. Surfaces in APM → **Database Query Performance** and in ITSI service `nwpay_l4_postgres` (8 KPIs: backends, cache, deadlocks, rollbacks, temp files, long-running txns, commits/sec, db size). Demo trigger: `scripts/incident.sh db-slow` — long-running-txns KPI flips red within ~60 s. |

---

## 5. Database — Avaloq (Oracle)

| Requirement | RAG | Splunk Capability | Proof | Comment |
|---|---|---|---|---|
| Oracle — locking, blocking, long queries, contention | GREEN | `oracledb` receiver; DB Monitoring license; versions 19c/26ai; RDS/RAC/self-hosted. | <https://help.splunk.com/en/splunk-observability-cloud/monitor-databases/get-data-in/configure-receivers/oracle-database-receiver> | **v1.0**: as above with details in *Oracle_Avaloq_Splunk_Observability_OTEL_Collector* documentation. **v1.1 status (tech swap)**: Oracle is not deployed in the demo (Postgres is the ledger backing store). The Postgres deep-dive in section 4 is the *evidence pattern*: same collector, same DBM screens, same ITSI KPI shape — only the receiver block changes (`oracledb` instead of `postgresql`). The Avaloq-specific OTel collector doc referenced above remains the canonical install guide for Oracle 19c / 23c (formerly "26ai") on RDS, RAC, or self-hosted. |

---

## 6. Dashboarding

| Requirement | RAG | Splunk Capability | Proof | Comment |
|---|---|---|---|---|
| Using tags | GREEN ✓ | OTel/cloud dimensions as tags in charts and navigators. | (Use tags or attributes in OpenTelemetry — see section 3) | **v1.0**: no caveat. **v1.1 demo evidence**: Tag Spotlight pivots by `customer.tier`, `payment.scheme`, `customer.location`, `payment.roaming`. Promoted via `scripts/05d-promote-metricsets.sh`; canonical list in `docs/operations/metricsets.md`. |
| Getting started / building dashboards | GREEN ✓ | Chart Builder, custom dashboards. | (Plot metrics and events) | **v1.0**: no caveat. **v1.1 demo evidence**: `terraform/dashboard.tf` provisions the demo's Splunk Observability dashboard; ITSI Glass Tables under `itsi/glass-table/` (`natwest-payments-overview.xml`, `natwest-customer-journey.xml`). |
| Creating SLOs | GREEN ✓ | Native SLOs in Alerts. | (Measure and track SLOs) | **v1.0**: no caveat. **v1.1 demo evidence**: `terraform/observability_slos.tf` provisions `signalfx_slo` resources for the demo's key journeys. |
| Overlay events on graphs | GREEN ✓ | Event Overlay on dashboards. | (Plot metrics and events) | **v1.0**: no caveat. **v1.1 demo evidence**: detector firings + chaos-audit notables (emitted by `emit_chaos_audit` in `scripts/incident.sh`) appear as Event Overlays on any chart filtered to the demo's environment. |
| Annotate graphs (collaboration) | GREEN ✓ | Custom events + suggested overlays. | (Splunk workshop — Event overlay) | **v1.0**: no caveat. **v1.1 demo evidence**: same pipeline; chaos-injection events are the equivalent of operator "annotation" markers and the audience can correlate them with KPI deflections in real time. |
| Configure log archives | GREEN | Splunk Platform index lifecycle (not O11y-native). | <https://help.splunk.com/en/data-management/manage-splunk-enterprise-indexers/9.2/back-up-and-archive-your-indexes/archive-indexed-data> | **v1.0**: no caveat. **v1.1 status**: Splunk Platform feature, not exercised in the demo. LOC into the in-cluster Splunk Enterprise (`terraform/splunk_enterprise.tf`) gives the customer a place to apply their existing index lifecycle policy. |
| Logging without limits (index exclusion) | GREEN | Splunk Platform index lifecycle. | — | **v1.0**: no caveat. **v1.1 status**: Splunk Platform feature, not exercised in the demo. |

---

## 7. Alerting

| Requirement | RAG | Splunk Capability | Proof | Comment |
|---|---|---|---|---|
| Synthetic — API (HTTP) | GREEN ✓ | API and Uptime tests. | <https://help.splunk.com/en/splunk-observability-cloud/digital-experience-monitoring/synthetic-monitoring/introduction-to-splunk-synthetic-monitoring> | **v1.0**: no caveat. **v1.1 demo evidence**: `terraform/observability.tf` provisions 3 Splunk Synthetics API tests via `null_resource.splunk_synthetic_*_check`. Gated on `var.splunk_synthetics_enabled=true` to avoid surprise device-minute spend. Also: 6 ThousandEyes synthetic tests via `scripts/08-configure-thousandeyes.sh` feed an L2 ITSI "Digital Customer Experience" tier (7 KPIs). |
| Synthetic — Browser | GREEN ✓ | Browser tests. | <https://dev.splunk.com/observability/reference/api/synthetics_browser/latest> | **v1.0**: no caveat. **v1.1 demo evidence**: same `terraform/observability.tf` file — `null_resource.splunk_synthetic_browser_check` provisions a real-browser test against the SPA login page. ThousandEyes TE-03 (page-load) and TE-04 (web transaction) provide a second, multi-geo browser-synthetic source. |
| Synthetic — Mobile (native app) | AMBER | Link HTTP monitors to mobile apps in RUM where supported; define mobile SLOs on API tests + RUM error/session metrics. | <https://help.splunk.com/en/splunk-observability-cloud/digital-experience-monitoring/synthetic-monitoring/introduction-to-splunk-synthetic-monitoring> | **v1.0**: no native mobile-app synthetic type; pattern is API synthetics for backends + Splunk RUM for mobile UX. **v1.1**: rating unchanged — confirmed AMBER. Concrete 5-step remediation in `docs/customer/path-to-green.md` (section B): add Splunk RUM mobile SDK to iOS + Android shells → define critical mobile journeys → provision Synthetics API tests against the same backend endpoints → define mobile SLOs in Splunk O11y (uptime via `synthetics.run.count`, UX via `application.start.time` + `crash.count`) → optional Device Farm / BrowserStack for real-device browser-level checks. |
| Splunk alerting / detectors / monitors | GREEN ✓ | Detectors and notifications. | <https://help.splunk.com/en/splunk-observability-cloud/create-alerts-detectors-and-service-level-objectives/create-alerts-and-detectors/create-detectors-to-trigger-alerts> | **v1.0**: no caveat. **v1.1 demo evidence**: `terraform/observability.tf` provisions ~22 `signalfx_detector` resources covering fraud error rate, SWIFT error rate, sanctions cache miss, ledger p99, tier decline rate, etc. Every detector has a custom message template with Mustache variables. |
| Monitor-based SLOs | GREEN ✓ | SLO from Synthetics (`synthetics.run.count`). | <https://help.splunk.com/en/splunk-observability-cloud/examples-and-tutorials/splunk-observability-cloud-examples/alerts-detectors-and-slos-examples/configure-a-service-level-objective-slo-based-on-a-synthetics-check> | **v1.0**: no caveat. **v1.1 demo evidence**: `terraform/observability_slos.tf` + the ThousandEyes synthetic tests feeding `kbs_synthetic_success` for the L2 Customer Channel ITSI KPI. |
| Customize notification messages | GREEN ✓ | Detector message templates + variables. | <https://help.splunk.com/en/splunk-observability-cloud/create-alerts-detectors-and-service-level-objectives/create-alerts-and-detectors/alert-message-variables-reference> | **v1.0**: no caveat. **v1.1 demo evidence**: every `signalfx_detector` in `terraform/observability.tf` carries a `description` with `{{inputs.A.value}}` / `{{ruleSeverity}}` Mustache templating. |
| Microsoft Teams integration | GREEN ✓ | Teams webhook integration on detectors. | <https://help.splunk.com/en/splunk-observability-cloud/create-alerts-detectors-and-service-level-objectives/send-alert-notifications-to-other-services/send-alerts-to-microsoft-teams> | **v1.0**: GREEN, documented only. **v1.1 demo evidence**: new file `terraform/teams_alert_bridge.tf` provisions a `signalfx_webhook_integration` pointed at a Teams Incoming Webhook URL behind two `TF_VAR_microsoft_teams_*` variables (commit `e4b85e3`). Off by default; one-shot enable: `export TF_VAR_microsoft_teams_alert_enabled=true; export TF_VAR_microsoft_teams_webhook_url="https://..."; terraform apply`. Concats into `obs_email_notifications`, so every existing detector picks the Teams channel up automatically — no per-detector edit required. Alerts land in the channel within ~30 s of a detector firing. |

---

## 8. Integrations

| Requirement | RAG | Splunk Capability | Proof | Comment |
|---|---|---|---|---|
| Checkmk — bidirectional alert push | GREEN (with caveat) | Checkmk → Splunk On-Call (REST) documented; not native O11y ↔ Checkmk bidirectional sync. | <https://docs.splunk.com/observability/en/sp-oncall/spoc-integrations/check_mk-integration.html>, <https://help.splunk.com/en/splunk-cloud-platform/alert-and-respond/splunk-on-call/integrations-with-splunk-on-call/checkmk-integration-for-splunk-on-call>, <https://docs.checkmk.com/latest/en/notifications_splunkoncall.html> | **v1.0**: review of current NatWest workflow required; bi-directional integration needs a third-party bridge; one-way REST works in Splunk Platform, not O11y. **v1.1**: rating unchanged — accurate as stated. Concrete 3-phase plan in `docs/customer/path-to-green.md` (section C): (1) Checkmk → Splunk HEC reusing the demo's `terraform/itsi_alert_bridge.tf` shape (effort ~2-3 d); (2) Splunk → Checkmk via O11y webhook + small auth-bridge service (effort ~5 d); (3) strategic: drop Checkmk in favour of the unified Splunk ITSI Episode Review pipeline this demo already ships (`itsi/correlation-searches/`, `itsi/aggregation-policies/payments_episode_policy.json`). |
| MS Insights / Azure metrics into Splunk | GREEN | Azure Monitor via Azure integration. | <https://help.splunk.com/en/splunk-observability-cloud/monitor-infrastructure/monitor-services-and-hosts/monitor-azure>, <https://help.splunk.com/en/splunk-observability-cloud/manage-data/connect-to-your-cloud-service-provider/connect-to-azure/azure-metrics> | **v1.0**: no caveat. **v1.1 status**: Azure integration is the documented path; not exercised in this demo because the demo cloud plane is AWS. Customer can enable in their own Splunk Observability tenant in ~15 min with a service principal — same operational pattern as the AWS integration the demo proves in section 3. |

---

## Summary of changes vs. v1.0

| Type of change | Count | Where |
|---|---:|---|
| RAG verdicts changed | 0 | All v1.0 ratings preserved. |
| GREEN rows upgraded to GREEN ✓ ("demonstrably proven") | 30 | Sections 1, 3, 4, 6, 7. |
| Rows materially extended in the demo to evidence the GREEN | 2 | Section 1 — `enduser.*` attributes (commit `41282e9`); Section 7 — Microsoft Teams alert bridge (commit `e4b85e3`). |
| AMBER rows with new remediation plan | 2 | Section 2 (MS Dynamics), Section 7 (mobile-app synthetics). |
| GREEN-with-caveat rows with new remediation plan | 1 | Section 8 (Checkmk bidirectional). |
| Tech-swap GREEN rows (documented pattern unchanged, not in demo) | 3 | Section 3 (ActiveMQ ↔ Kafka), Section 5 (Oracle ↔ Postgres), Section 1 (iOS/Android ↔ Browser). |

Companion files in this repo:

- [`docs/customer/path-to-green.md`](./path-to-green.md) — full prose
  mapping including the 20-minute customer walkthrough script.
- [`README.md`](../../README.md) — links the customer walkthrough from
  the presenter pack.
