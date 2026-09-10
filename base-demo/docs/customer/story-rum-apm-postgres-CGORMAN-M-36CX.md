# Unified demo story: RUM → Session Replay → APM → Metrics → Logs → Postgres

**Audience**: SRE / platform / DBA stakeholders who want to see Splunk
Observability behave as one product across the digital experience,
application, and database planes.

**Goal**: end-to-end correlation. Start at "a customer clicked submit",
finish at "this specific Postgres query held this row lock for 400 ms
and here's the log line that fired in the same trace". Single trigger
on the demo, single Episode in ITSI, single story for the audience.

**Trigger**:

```bash
scripts/incident.sh payment-meltdown
```

Or from the SPA Chaos Dashboard at `/?ops=1#/ops`, click the
**Payment meltdown (db-slow → postgres-out)** tile in the *Customer
stories (multi-act)* section. The button drives the same two-act
sequence as the CLI orchestrator — same default pacing, same
auto-recover, same `story_id` stamped on every chaos audit event so the
SIEM stitches the run into a single ITSI Episode. The card surfaces
live phase + elapsed/remaining + `story_id` while the run is in flight,
and the **Clear** button aborts mid-flight and restores baseline
(safe to click at any time).

If you prefer to drive each act manually for a slower walkthrough,
click **db-slow** alone, walk Act 1, then click **postgres-outage**,
walk Act 2, then **Clear**. The CLI orchestrator is for headless /
SSH-only sessions; the one-click SPA path gives the same data with
the *Recover all* button held in reserve as a hard kill-switch.

---

## Why these two scenarios

| Scenario | Coverage |
|---|---|
| **`db-slow`** (Act 1: *grey failure*) | RUM (SPA spinner stalls) → Session Replay (audience sees the wait) → APM (ledger-service p99 climbs) → **Metrics & DB Query Performance** (`SELECT pg_sleep` appears in pg_stat_statements) → ITSI `nwpay_l4_postgres` KPIs deflect → Logs (trace-linked) |
| **`postgres-outage`** (Act 2: *blast radius*) | RUM (SPA fails) → Session Replay (rage-clicks) → APM (`ledger-service` 5xx, inferred-Postgres edge red) → **Logs** (`PSQLException: Connection refused` in `index=main sourcetype=kube:container:service`, with the same `trace_id` as the failed APM span) → ITSI `nwpay_l4_postgres` (backends online = 0) → Episode Review (Act 1 + Act 2 stitched by `story_id`) |

Together they cover every product surface and stay topical (one
storyline, one cast of services). The other chaos scenarios
(`fraud-cpu-regression`, `tail-latency-storm`, `cache-cold`,
`kafka-broker-down`, ...) showcase real value but they break the story
at the Postgres step — leave them for the per-feature deep-dives.

---

## What was changed to make this work

The original `db-slow` injected its latency in **Java** with a
`Thread.sleep` *after* the JDBC calls. APM service health degraded but
the JDBC spans themselves were not slow and Postgres-side telemetry
(`pg_stat_statements`, postgres_exporter, ITSI Postgres KPIs) did not
move — so the "trace → DB Query Performance → pg_stat_statements" arc
had no payoff.

Now (`services/ledger-service-java/src/main/java/com/natwest/payments/ledger/`):

```java
// LedgerEntryRepository.java - new method
@Query(value = "SELECT pg_sleep(:seconds)", nativeQuery = true)
Object chaosPgSleep(@Param("seconds") double seconds);

// LedgerController.java - inside the @Transactional process() method
if (dbLatencyMs > 0) {
    long capped = Math.min(dbLatencyMs, 30_000L);
    repo.chaosPgSleep(capped / 1000.0);
}
```

Effect — the same `DB_LATENCY_MS=400` toggle now also lights up:

| Surface | Before | After |
|---|---|---|
| APM service health (`ledger-service` p99) | ✓ | ✓ |
| APM trace waterfall (slow JDBC span) | ✗ (silent "thinking" gap) | ✓ (slow span attributed to `db.system=postgresql`) |
| APM **Database Query Performance** | ✗ | ✓ (`SELECT pg_sleep` in top-N) |
| `pg_stat_statements` top-slow | ✗ | ✓ |
| postgres_exporter active backends | ✗ | ✓ (concurrent payments → backend count rises) |
| ITSI `nwpay_l4_postgres` KPIs | ✗ | ✓ |

And as defence-in-depth: the controller catches a runtime exception
from `chaosPgSleep` and falls back to a Java sleep, so the demo never
hard-fails because the database is in a weird state.

The orchestrator (`scripts/incident.sh payment-meltdown`) and the
`recover` subcommand both gained a `story_id` field on their chaos-audit
events. The SIEM correlation searches stitch the two acts into a single
ITSI Episode so the audience sees one ticket per story, not two.

---

## 2026-06-19 — "full chain" remediation (read this before demoing db-slow)

The `pg_sleep` code above was **committed but never shipped**. The arc
("trace → DB Query Performance → `pg_stat_statements` → ITSI Postgres")
was silently dead in the live cluster for ~6 weeks. This section records
the root cause, the fix, and how to re-verify, so the next operator does
not re-discover it the hard way.

### Root cause — stale image

| Evidence | Finding |
|---|---|
| `kubectl -n natwest get deploy ledger-service -o jsonpath='{…image}'` | Cluster was running `…/natwest-payments-ledger-service-java:0.1.1`, **built 2026-04-26** (`app.jar` mtime). |
| `git log -1 ab1900e` (the `pg_sleep` commit) | Dated **2026-06-09** — i.e. the running image predated the `pg_sleep` change by 6 weeks. |
| `pg_stat_statements WHERE query ILIKE '%pg_sleep%'` | **Zero rows** — `pg_sleep` had never executed against Postgres. |
| ledger logs during `db-slow` | HikariCP `Connection is not available, request timed out` **but no** `falling back to Java sleep` line. |

So `0.1.1` was the **pre-`pg_sleep`** build: it injected `DB_LATENCY_MS`
as a `Thread.sleep` *inside* the `@Transactional process()` method. That
held a pooled connection open for the sleep duration (→ real HikariCP
pool exhaustion, the "drama") but issued **no SQL**, so:

- no slow JDBC span in the trace waterfall,
- nothing in `pg_stat_statements` / APM Database Query Performance,
- ITSI `nwpay_l4_postgres` stayed flat.

This is *why* the earlier investigation saw the Hikari cascade in O11y
but never the `SELECT pg_sleep` "why". The fix is not a code change —
the committed source already does the right thing — it is **shipping
the committed source**.

### The fix — rebuild & roll out (keep latency high)

```bash
# from services/ledger-service-java
aws ecr get-login-password --region eu-west-2 \
  | docker login --username AWS --password-stdin 236881431638.dkr.ecr.eu-west-2.amazonaws.com

docker buildx build --platform linux/amd64 \
  -t 236881431638.dkr.ecr.eu-west-2.amazonaws.com/natwest-payments-ledger-service-java:0.1.7 \
  --push .

# NB: the deployment container is named "service", not "ledger-service".
kubectl -n natwest set image deploy/ledger-service \
  service=236881431638.dkr.ecr.eu-west-2.amazonaws.com/natwest-payments-ledger-service-java:0.1.7
kubectl -n natwest rollout status deploy/ledger-service
```

`DB_LATENCY_MS` is patched onto the deployment by the chaos-controller
at inject time, so it survives `set image` — the scenario stays armed
across the rollout. We intentionally kept it at **1500 ms** (not the
historic 400 ms) so the demo carries *both* signals at once.

### Why 1500 ms gives the full chain (HikariCP math)

`application.yml`: `maximum-pool-size: 16`, `connection-timeout: 3000ms`.
At 1500 ms per `pg_sleep`, each in-flight payment parks one of the 16
connections for 1.5 s. Under the demo's steady payment load that
saturates the pool, so:

- requests that **get** a connection run the slow query → emit the
  `SELECT pg_sleep($1)` JDBC span and land in `pg_stat_statements`
  (the **where / why-1: slow query**);
- requests that **can't** get one within 3 s throw
  `Connection is not available, request timed out` → cascading 5xx
  (the **why-2: connection-pool exhaustion**).

Lowering to ~600–800 ms would remove the pool drama and give only the
clean slow-query story; 1500 ms keeps the richer "impact → where → why"
narrative on purpose.

### Verification (run after any redeploy)

```bash
# 1) pg_sleep is now a real, dominant query  (expect mean ≈ 1501 ms)
echo "SELECT calls, round(mean_exec_time::numeric,0) mean_ms, left(query,30) \
  FROM pg_stat_statements WHERE query ILIKE '%pg_sleep%' ORDER BY total_exec_time DESC LIMIT 3;" \
  | kubectl -n natwest exec -i deploy/postgres -c postgres -- psql -U ledger -d ledger -tA

# 2) the connection-pool cascade is still firing (the drama)
kubectl -n natwest logs deploy/ledger-service -c service --since=90s \
  | grep -icE "Connection is not available|request timed out"

# 3) we are NOT silently falling back to a Java sleep (expect 0)
kubectl -n natwest logs deploy/ledger-service -c service --since=90s | grep -ic "falling back"
```

Observed on 2026-06-19 immediately after rolling out `0.1.7`
(`DB_LATENCY_MS=1500`):

| Signal | Result |
|---|---|
| `pg_stat_statements` `SELECT pg_sleep($1)` | 1151 calls, **mean 1501 ms**, top query by total time |
| `pg_stat_activity` active backends | **17 / 17** active sessions are `pg_sleep` |
| Slow JDBC span in `index=otel_traces` (last 5 min) | ~1700 `SELECT` spans, **avg ≈ 1509 ms** (none before the rollout) |
| HikariCP timeouts (90 s window) | **970** `Connection is not available` lines |
| Java-sleep fallback | **0** (genuine Postgres slow query) |

> The JDBC instrumentation names the span `SELECT` (no table — `pg_sleep`
> is a function), but APM **Database Query Performance** shows the
> sanitised statement `SELECT pg_sleep(?)`, which is the top entry by
> total time. That is the tile to land on in step 5 of Act 1.

### ITSI side (companion changes, same investigation)

So ITSI actually *reflects* `db-slow` (it previously did not):

- The chaos-targeted KPIs (`p99 latency`, `error rate`, gateway/throttle)
  were de-sentinelled — their bootstrap thresholds were placeholders
  (e.g. critical = 999999) that could never trip. Realistic thresholds
  applied (p99 latency medium **500 ms** / critical 800 ms; error rate
  medium 0.02 / critical 0.05).
- Those KPIs were converted from the **shared base search** to scoped
  **ad-hoc** searches with a `service.name="<service>"` filter baked into
  `base_search`, so each service reads *its own* latency/error instead of
  the global APM aggregate. (The shared-base + entity-filter route was
  tried first and rejected by ITSI with
  *"Cannot generate searches when filtering on entities in service"*.)
- **Postgres "active backends" KPI re-pointed to pool-in-use
  (2026-06-19).** Every `nwpay_l4_postgres` KPI shipped with *empty*
  thresholds, so the Postgres tiles could never deflect. Server-side
  `pg_stat_database_numbackends` is too noisy to threshold (baseline
  drifts 60–110 with idle connections — thresholding it would recreate
  the SWIFT "permanent amber" problem). Instead the "Postgres active
  backends" KPI was converted to an ad-hoc metrics search on the
  HikariCP gauge:
  `| mstats avg(_value) AS used WHERE index=itsi_im_metrics metric_name="db.client.connections.usage" state="used" span=1m`
  with ascending thresholds **medium 10 / critical 14** (pool max 16).
  Baseline pool-in-use is ~0–2 (green); db-slow pins it at **16/16
  (critical/red)** with no false positives. So the Postgres KPI tile now
  clearly reflects db-slow.
- **Node-colour caveat (ITSI limitation).** The Postgres *node colour* in
  Service Analyzer still reads green-ish during db-slow even with that
  KPI critical. This service's health score is an **equal-weight % of
  healthy KPIs** (8 KPIs → one critical = 87.5, which ITSI's default
  ServiceHealthScore thresholds treat as "normal"). KPI **importance** is
  ignored by this calc, and per-service **ServiceHealthScore threshold
  edits auto-revert** to the platform default (normal ≥80). To make the
  *node* flip amber/red under db-slow, trim `nwpay_l4_postgres` to the few
  meaningful KPIs (so one critical dominates the denominator) or add
  several db-slow-sensitive KPIs (`db.client.connections.pending_requests`,
  `db.client.connections.timeouts`) so multiple go critical together. The
  honest, always-reliable db-slow rollup remains on `ledger-service`
  `p99 latency` → Ledger & Settlement → Payment Services.
- **SWIFT (`nwpay_l3_swift_network`) baseline de-noised (2026-06-19).**
  SWIFT is a slow cross-border network by design — baseline **p99 ≈ 5.2 s**
  and **error rate ≈ 4.8 %**, which kept tripping the generic 500/800 ms
  and 2/5 % thresholds and left the node (and its "Payment Networks"
  parent) permanently red with no chaos running. Fixed by switching the
  latency KPI from p99 → **p95** (baseline ≈ 414 ms; title now
  "p95 latency") with thresholds medium 800 ms / critical 1500 ms, and
  raising error-rate thresholds to medium 0.08 / critical 0.15. SWIFT now
  sits green at baseline and still trips under a genuine SWIFT
  degradation. Sibling networks (bacs/chaps/sepa/fps/cheque) were already
  green (p99 137–250 ms, errors <1.1 %) and were left unchanged.

### Operational note — clearing

`db-slow` clears the normal way (SPA **Clear** / `scripts/incident.sh
recover`), which sets `DB_LATENCY_MS=0` back on the deployment and
`pg_sleep` stops immediately. Leaving it armed pins 16 connections and
~95 %+ 5xx, so don't leave it on between demos.

---

## Pacing

| Phase | Default | Override | What you do during this phase |
|---|---|---|---|
| Act 1 (slow query) | 240 s | `MELTDOWN_ACT1_S=N` | Walk surfaces 1-6 below. |
| Act 2 (outage) | 120 s | `MELTDOWN_ACT2_S=N` | Walk surfaces 7-10 below. |
| Recover | auto | `MELTDOWN_AUTORECOVER=0` to keep broken | Optional Q&A on Episode Review. |

Total ~6 minutes including recovery. The defaults assume one operator
on a webcam — for a high-engagement room you can compress to
`MELTDOWN_ACT1_S=120 MELTDOWN_ACT2_S=60`.

---

## Click-by-click — Act 1 (db-slow)

| # | Splunk surface | What to do | What the audience sees | Value point evidenced |
|---:|---|---|---|---|
| 1 | **SPA** (`http://itsi.splunk-observability.com/`) | Log in as **Margaret (Gold)**. Submit a payment. | Submit-button spinner is visibly slower than baseline (~500 ms vs ~80 ms). | Customer-perceived impact. |
| 2 | **Splunk Web → RUM → Sessions** | Filter `enduser.id = margaret*`, open the latest session. | Page-action span for `/api/process` shows duration ~700 ms. | RUM session captures the real-world UX. |
| 3 | Same session → **Replay** | Press play. Watch the persona click Submit, wait through the spinner. | Audience sees the wait in real-time playback. | Session replay = the *qualitative* signal next to the metric. |
| 4 | Same session → **Backend trace** (link) | One click. | APM waterfall for the trace; `ledger-service` span is the long one; inside it, a JDBC client span `SELECT pg_sleep ($1)` carries the duration. | RUM ↔ APM trace correlation, zero seams. |
| 5 | **APM → Service Map → ledger-service → Database Query Performance** | Filter time-range to "last 5 min". | `SELECT pg_sleep ($1)` is now the top entry by total-time, well above any business query. | APM Metrics & Database Query Performance. |
| 6 | **APM trace** (from step 4) → **Logs for this trace** (button) | One click. | Log Observer Connect opens, pre-filtered to the matching `trace_id`. Shows the `ledger-service` request log lines, each carrying `customer.tier=gold`, `payment.scheme=FPS`. | Trace ↔ log correlation via Log Observer Connect. |
| 7 | **ITSI → Service Analyzer → `nwpay_l4_postgres`** | Click. | "Active backends" KPI tile shows the slow-query concurrency bump; "cache hit ratio" dips. | Postgres database monitoring — the same trace data + native receiver feeding ITSI. |

*Act 1 in one sentence*: "Margaret felt a slow Submit; one click took us
from her session replay into the backend trace, the slow JDBC span, the
exact SQL in Database Query Performance, the log lines emitted on that
trace, and the matching ITSI Postgres KPI tile — every layer of the
stack, one story."

---

## Click-by-click — Act 2 (postgres-outage)

| # | Splunk surface | What to do | What the audience sees | Value point evidenced |
|---:|---|---|---|---|
| 7 | **SPA** | Refresh, submit again. | Error toast: "Could not process payment". Click Submit a few more times. | Customer-perceived outage. |
| 8 | **Splunk Web → RUM → Sessions** | Open the latest session, switch to **Frustration Signals** view. | Rage-click cluster on the Submit button is auto-detected by RUM. Replay shows the persona clicking 4-5 times. | RUM frustration signals = automatic UX detection of the outage. |
| 9 | **APM → Service Map** | Look at the `ledger-service` node. | Error-rate ring goes red; the inferred-`postgres` edge greys out or breaks. | Blast-radius visualisation in APM. |
| 10 | Pick any failed `ledger-service` trace → **Span detail** → **Logs for this trace** | One click. | Log line: `org.postgresql.util.PSQLException: Connection to postgres:5432 refused`. Same `trace_id` as the failed APM span. | Trace ↔ log correlation works even on failure paths. |
| 11 | **ITSI → Service Analyzer → `nwpay_l4_postgres`** | Same tile as Act 1. | Now red: backends online = 0, query latency = no data. | Postgres database monitoring in failure mode. |
| 12 | **ITSI → Episode Review** | Filter to the last 10 min. | One Episode for "NatWest payments" with both Act 1 and Act 2 notables attached, stitched by `story_id`. | Episode Review = unified Splunk pipeline replacing third-party alert correlation. |

*Act 2 in one sentence*: "We escalated from 'slow' to 'down' with one
click; the same six Splunk surfaces showed the new failure mode without
needing a new tool, a new console, or a new query."

---

## Variations

- **Quick run (no Replay enabled)** — same trigger, skip steps 3 and 8.
  Saves ~2 min, loses the "audience sees the wait" beat.
- **DBA-centric audience** — start at step 5, then back up to step 1 if
  the audience asks "how did you know to look there?". This is the same
  data, different entry point.
- **Without LOC enabled** — replace step 6 / step 10 with searching
  `index=main "trace_id=…"` directly in Splunk Platform. Same trace
  correlation, one more click.
- **Without ITSI** — replace step 7 / step 11 with the Splunk
  Observability dashboard tile for Postgres (`terraform/dashboard.tf`).
  Same KPIs, different chrome.

---

## Files involved

```
services/ledger-service-java/.../LedgerEntryRepository.java   chaosPgSleep() native query
services/ledger-service-java/.../LedgerController.java         calls chaosPgSleep inside @Transactional
scripts/incident.sh                                            cmd_payment_meltdown orchestrator (CLI)
chaos-controller/app/orchestrators.py                          MeltdownRunner (SPA-button orchestrator)
chaos-controller/app/scenarios.py                              payment-meltdown catalog entry + narratives
frontend/src/pages/Ops.tsx                                     "Customer stories" group + progress block
docs/customer/path-to-green.md                                 walkthrough section 1 + section 4
docs/customer/path-to-green-requirements-v1.1.md               sections 1, 4, 7 GREEN ✓ rows
itsi/service-tree.yaml                                         nwpay_l4_postgres KPI definitions
helm/natwest-payments/templates/postgres.yaml                  postgres_exporter sidecar config
collector/values.yaml                                          native postgresqlreceiver pipeline
```

---

## Pre-flight checklist

```bash
# 1. Demo is healthy?
scripts/00-preflight.sh

# 2. Postgres is the deployment name we expect?
kubectl -n natwest get deploy postgres -o jsonpath='{.spec.replicas}'   # should be 1

# 3. Session Replay enabled in this tenant? (One-off; survives across runs.)
#    Splunk Web -> Settings -> Organization Overview -> "Session Replay" = ON

# 4. LOC connected to the in-cluster Splunk Enterprise?
#    Splunk Web -> Data Management -> Log Observer Connect -> shows nwpay connection healthy

# 5. ITSI bootstrapped?
scripts/07-itsi-bootstrap.sh

# 6. *Chart-overlay primer* - one-off, ~3 minutes. Turn on the
#    `chaos.scenario.*` events overlay on each chart you plan to show
#    (APM Service Map, RUM Sessions list, Postgres infra dashboard).
#    See docs/customer/chaos-events-overlay.md for click-by-click.
#    Result: every act of the story plants a vertical pin labelled
#    "scenario=payment-meltdown phase=act-2-postgres-outage" on each
#    chart the moment you trigger it - this is the single biggest
#    "wow" of the talk track, and it survives across demo runs.

# 7. Fire the story (full default pacing).
scripts/incident.sh payment-meltdown

# 8. Recover cleanly at any point.
scripts/incident.sh recover
```

---

## 2026-06-19 — `microservice` entity type + APM Service Map drilldown (ITSI)

The `ledger-service` and `postgres (in-cluster)` ITSI services now expose a
**`microservice`** entity type whose entities deep-link straight to **Splunk
Observability Cloud → APM Service Map**, so the demo can go ITSI service →
entity → APM in one click.

**Entity type** `nwpay_et_microservice` (title: *microservice*) — dashboard
drilldowns (both `navigation_link`, realm `eu0`):
- *Splunk Observability - APM Service Map* → `https://app.eu0.signalfx.com/#/apm/service-map?service=${service_name}`
- *Splunk Observability - APM Service View* → `https://app.eu0.signalfx.com/#/apm/troubleshooting?service=${service_name}`
- data drilldown → in-product `otel_traces` index filtered on `service.name`.

The `${service_name}` token is substituted from the entity's `service_name`
field (same `${field}` pattern proven on `nwpay_et_k8s_deployment`).

**Entities tagged `microservice`:**
| Entity (`_key`) | service | `service_name` (→ APM node) | also typed |
|---|---|---|---|
| `ent_ledger_service` | `nwpay_l3_ledger_service` | `ledger-service` | — |
| `ent_pg_db_ledger` | `nwpay_l4_postgres` | `postgres` | `postgres_database` |
| `ent_pg_db_postgres` | `nwpay_l4_postgres` | `postgres` | `postgres_database` |

The two Postgres entities (the ones shown under the *Postgres active backends*
KPI) keep their original `postgres_database` type and gain `microservice` as a
second type, so clicking either entity in Service Analyzer offers the APM
Service Map link to the inferred `postgres` node. Ledger maps to the
`ledger-service` APM node.

Click path: Service Analyzer → select `ledger-service` / `postgres (in-cluster)`
→ open the entity → **Splunk Observability - APM Service Map** → lands on the
APM Service Map with that service selected (then drill to the slow `pg_sleep`
span as per the full-chain story above).

**Gotcha (important):** `navigation_link` drilldowns are hidden in Service
Analyzer unless the entity type has `show_navigation_in_service_analyzer: true`
(and `show_dashboards_in_service_analyzer: true` for dashboard-type drilldowns).
These default to `false`. `nwpay_et_microservice` now has both `true`. If you
clone this pattern elsewhere and the Drilldowns column is empty, this flag is
almost always the cause — flip it and hard-refresh Service Analyzer.
