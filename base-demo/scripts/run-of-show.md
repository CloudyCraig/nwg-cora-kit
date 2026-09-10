# Run of show — NatWest payments demo

A two-act walkthrough. **Act I is the money beat: a single 6-minute
complaint-to-commit narrative** that takes the audience from a slow
customer click in the browser, through the trace, into the structured
log, and onto the line of code that broke it — every Splunk
Observability surface used in service of one story. Act II is the
guided tour of breadth: Service Map, Tag Spotlight, Detectors,
Synthetics, the dashboard. Total runtime ~20 minutes incl. Q&A buffer.

> **Prerequisites**
>
> - `scripts/00-provision.sh`, `01-build-push.sh`, `02-install-collector.sh`, `03-deploy.sh`, `04-start-traffic.sh` and `05-deploy-frontend.sh` have all completed successfully.
> - `terraform apply` has been run with `splunk_observability_enabled=true`, populating the detectors and dashboard.
> - **APM MetricSets promoted** (one-time per tenant): `customer.tier`, `customer.location`, `payment.scheme`, `payment.roaming`, and the other six tags in [`scripts/lib/metricsets.json`](lib/metricsets.json) must exist as Troubleshooting MetricSets (plus the four marked `monitoring: true` as Monitoring MetricSets) before the Service Map's **Breakdown** dropdown and Tag Spotlight pivots will surface the demo's business attributes. Run `scripts/05d-promote-metricsets.sh` (best-effort API + manual fallback) or follow [`docs/operations/metricsets.md`](../docs/operations/metricsets.md).
> - Splunk Synthetics: `[NatWest demo] payments gateway` (API POST), optional `[NatWest demo] SPA health` (GET `/healthz`), and `[NatWest demo] payments SPA` (browser) are provisioned when `splunk_synthetics_enabled = true` and each URL variable is set. See `terraform/observability.tf` (`null_resource.splunk_synthetic_*`) and `scripts/lib/synthetic_check.sh`, `synthetic_spa_health_check.sh`, `synthetic_browser_check.sh`.
> - The presenter has Splunk Observability open in one browser tab, the demo SPA (`http://<web-frontend-elb>/`) in a second, and a terminal with `kubectl` configured against the cluster in a third.
> - `scripts/incident.sh status` shows all values at baseline.
>
> **Pre-arm the incident, ~3 min before stage time:**
>
> ```bash
> scripts/incident.sh fraud-cpu-regression
> ```
>
> By the time the customer is watching, fraud-detection-service has been
> running the quadratic kernel long enough for AlwaysOn Profiling to
> have sampled both the baseline and the regressed flame graphs — the
> profiling-diff view will be ready to land in seconds, not minutes.
>
> **AWS SCP / blocked LoadBalancer fallback.** Some AWS Org accounts deny
> `elasticloadbalancing:CreateLoadBalancer` (you'll see the
> `web-frontend` Service stuck in `<pending>` with `SyncLoadBalancerFailed`).
> In that case redeploy the frontend with `FRONTEND_SERVICE_TYPE=ClusterIP`
> (or `NodePort`) and run **`scripts/05a-frontend-portforward.sh`** to
> reach the SPA on `http://localhost:8080/`. RUM still ships traces to
> Splunk Observability over the public ingest endpoint, so every product
> surface (Sessions, APM, Profiling, Detectors, Synthetics, Dashboard)
> works identically — only the URL the presenter types is different.

---

## Slide cue: "A customer just complained their payment is slow."

# Act I — The 6-minute complaint-to-commit walkthrough

Single narrative. One trace. The point is not to show every product —
it is to show one investigation that happens to use every product, and
finishes on a line of code.

## 1 · The customer complaint (Splunk RUM)  ⏱ 60 sec

1. Open the SPA in a fresh browser tab. Submit one **SWIFT** payment.
   The click feels notably slower than it did during last week's
   walkthrough.
2. Switch to **RUM → Sessions** and open the session you just created.
3. Show the page-action span for the **Send payment** click. Highlight
   that the span carries `traceparent` headers — the SDK has already
   tied this customer's experience to a server-side trace.
4. Click **APM trace** from the RUM span.

> **Talk track:** "Forty-seven seconds ago this user pressed Send.
> They saw a 1.4-second wait. We don't have to ask them for a reference
> number, screenshots, anything — RUM has already linked their click
> to the back-end trace via W3C trace context."

## 2 · The slow span (Splunk APM)  ⏱ 75 sec

1. The trace lands in **APM → Trace**. Walk down the call tree:
   `web-frontend → api-gateway → payment-initiation-service →
   fraud-detection-service`.
2. Stop on the **fraud-detection-service** span. Point out:
   - The `compute_fraud_features` child span — that's the **CPU-bound
     work**, the new code in this release.
   - `fraud.algo = pairwise` and `fraud.feature_count = 96` — business
     attributes you can pivot on.
   - Span duration is several hundred ms, dominating the trace.
3. While there, point sideways at the `ledger-service` JDBC spans:
   `db.system = postgresql`, `db.statement = INSERT INTO ledger_entry …`
   and `SELECT SUM(amount_minor) …`. **DB Query Performance** in APM
   buckets these by template — there's the slow-query view, no extra
   instrumentation, no Postgres exporter.

> **Talk track:** "The slow span is fraud-detection. We've got a
> hypothesis. Now I want the log line that this code wrote, in this
> request, on this pod, on this trace."

## 3 · Logs in context (`kubectl logs` + trace_id pivot)  ⏱ 45 sec

1. Copy the `trace_id` from the APM trace.
2. In the terminal:

   ```bash
   kubectl -n natwest logs -l app.kubernetes.io/name=fraud-detection-service \
     --tail=2000 --prefix \
     | jq -c "select(.trace_id == \"<paste>\")"
   ```

3. The structured JSON log line for this exact request appears,
   complete with `service`, `level`, `trace_id`, `span_id`,
   `payment_id` and `payment.scheme=SWIFT`.

> **Talk track:** "Every service emits structured JSON with the trace
> and span id baked in. With Log Observer Connect to a Splunk Cloud
> Platform stack we can pivot from this APM trace into the matching
> log line in one click — production NatWest already has that.
> Today we're showing the wire format and the correlation; the click is
> a thirty-second config change away."

## 4 · The line of code (AlwaysOn Profiling diff)  ⏱ 90 sec

1. Back in APM, on the `fraud-detection-service` span, expand
   **AlwaysOn Profiling**.
2. Open the **CPU flame graph**. The widest stack frame is
   `_extract_features_pairwise` inside `compute_fraud_features`.
3. Switch to **Profiling diff**, comparing the last 5 minutes against
   the baseline before the bad deploy. The new tower is unmistakable:
   `_extract_features_pairwise` is brand new, on a hot path, eating
   the request budget.

> **Talk track:** "AlwaysOn Profiling samples every JVM and Python
> process in the cluster, all the time, in production, for ~1% CPU
> overhead. The diff view is what makes a slow trace actionable: it
> tells you not just that fraud-detection regressed, but **which line
> of which file** regressed it. Same trace ID, same business context,
> from RUM all the way down to the stack frame."

## 5 · Recover and commit  ⏱ 30 sec

1. In the terminal:

   ```bash
   scripts/incident.sh recover
   ```

2. As the deploy rolls (~30 s), narrate the customer-facing fix:

> "In the real workflow this is the moment you'd revert the PR or
> push the fix. We're flipping the algorithm flag back to the linear
> kernel — same observability story watching it heal: p99 settles,
> the regression tower disappears from the flame graph, error budget
> stops bleeding, customer click times return to baseline."

3. Refresh the SPA — the next payment goes through fast again.

## Slide cue: "RUM → Trace → Log → Profile, in six minutes, on one page."

---

# Act II — The guided tour  ⏱ ~12 min

Now that the audience has seen one full investigation, walk them
through the rest of the platform's breadth. Each step is short — the
heavy lifting is done.

## A · Service map: 24 services, polyglot, async  ⏱ 3 min

1. Open **APM → Service Map**, scoped to `environment=demo`.
2. Point out:
   - 24 microservices auto-discovered.
   - Inferred infrastructure nodes: **Redis**, **Postgres**, **Kafka**.
   - The **dotted Kafka edge** between `payment-initiation-service`
     and `settlement-service`.
   - The polyglot **`ledger-service`** (Java) and the Python services
     coexisting with no visual seam.
3. Click the Postgres node — DB Query Performance again, this time
   from the infra view rather than a single trace.

> **Talk track:** "OpenTelemetry's auto-instrumentation does the heavy
> lifting. The mesh you're seeing was built by deploying services and
> walking away — no per-service tracing PRs."

## B · Tag Spotlight: business questions, not span queries  ⏱ 3 min

1. Open **APM → Tag Spotlight** for `payment-initiation-service`,
   last hour.
2. Pivot by `payment.scheme`: SWIFT has the highest p99 and error
   rate.
3. Pivot by `customer.tier`: Bronze, Silver, Gold are emitted on every
   span (front-end persona switcher and load-gen `TIER_MIX` keep them
   populated). Gold p95 lands well below Bronze because the
   fraud-detection fast-path skips the heavy kernel for higher tiers
   — the same trace tells the latency *and* the segmentation story.

> **Talk track:** "Every span carries business context, so 'which
> customer segment is hit hardest?' is a pivot, not a JIRA ticket
> for the data team."

## C · Detectors and SLOs  ⏱ 3 min

In a terminal next to the Splunk window, kick off a second incident:

```bash
scripts/incident.sh swift-counterparty-flap
```

While it rolls out (~30 s):

1. Switch to **Detectors & SLOs → Active Alerts**.
2. The `[NatWest demo] SWIFT error rate` detector fires Critical.
3. Click through to the alert detail; show the chart with the
   threshold band crossed.
4. Click the runbook URL.

> **Talk track:** "Detectors don't replace your eyes — they buy them
> back. The team sleeps; the platform watches."

Optional escalation library, depending on appetite:

```bash
scripts/incident.sh bad-deploy-fraud      # bumped error rate, model rollback story
scripts/incident.sh cache-cold            # sanctions cache redeployed
scripts/incident.sh db-slow               # Postgres index dropped
scripts/incident.sh inject-tier-throttle bronze   # Bronze decline detector + SPA story
```

The Bronze throttle scenario is the "customer-tier" story: the gateway
starts declining ~30% of Bronze traffic, the Bronze-decline detector
goes Critical within ~3 minutes, the **Decline + throttle rate by
customer tier** chart shows the Bronze line jump while Silver and Gold
stay flat, and the SPA persona switcher (Olivia/Bronze) reproduces
the failure live for the audience.

Recover with:

```bash
scripts/incident.sh clear-tier-throttle   # api-gateway TIER_THROTTLE_PROB back to 0
```

(or just `scripts/incident.sh recover`, which folds this into the
all-incidents reset).

## D · Synthetic + Dashboard  ⏱ 3 min

1. Switch to **Synthetic Monitoring → `[NatWest demo] payments gateway`**.
   The per-minute results chart shows the spike during this incident
   and recovery after `recover`.
2. Switch to **Dashboards → `[NatWest demo] Payments Operations`**:
   - **RPS by scheme** — the time-of-day curve.
   - **p99 latency by scheme** — the SWIFT spike.
   - **Cache hit ratio** — would dip during `cache-cold`.
   - **GBP volume processed** — the VP-of-Payments single metric.
   - **p95 latency by customer tier** — Gold visibly below Bronze.
   - **Decline + throttle rate by customer tier** — Bronze spikes
     during `inject-tier-throttle bronze`; Silver / Gold flat.
   - **Customer tier mix** — the live persona pool right now.
3. Run `scripts/incident.sh recover`.

## Closing

> "RUM, APM, Profiling, Logs, Detectors, Synthetics and the Dashboard
> all share the same data plane and the same dimensions. One mental
> model, one set of tags, and one place where every signal converges
> into a story. The bit you watched in the first six minutes is what
> a NatWest engineer's Tuesday afternoon should look like."

---

## Timing summary

| Act | Surface                                  | Time |
|-----|------------------------------------------|------|
| I.1 | RUM complaint                            | 1 min |
| I.2 | APM trace + DB Query Performance         | 1.25 min |
| I.3 | Logs-in-context via trace_id             | 0.75 min |
| I.4 | AlwaysOn Profiling diff                  | 1.5 min |
| I.5 | Recover + commit                         | 0.5 min |
| II.A | Service map breadth                     | 3 min |
| II.B | Tag Spotlight pivots                    | 3 min |
| II.C | Detectors & SLOs                        | 3 min |
| II.D | Synthetics + Dashboard                  | 3 min |
|     | **Total**                                | **~20 min** |

Add 2–3 minutes of customer Q&A buffer between every step.

## Verifying the synthetic business view (ITSI side)

The "Synthetic-driven business view" tiles on the ITSI glass table
and the matching `nwpay_l2_synth_outcomes` service tree node are
populated by `scripts/07-itsi-bootstrap.sh`. After `scripts/08`,
`09`, `09b`, `10` have run successfully, do a 30-second walkthrough
of the new surface so you know it's lit before you go on stage:

```bash
# 1. Confirm the new ITSI service exists
ssh -i terraform/splunk-enterprise.pem ec2-user@itsi.splunk-observability.com \
  "curl -sk -u admin:$TF_VAR_splunk_enterprise_admin_password \
   https://localhost:8089/servicesNS/nobody/SA-ITOA/itoa_interface/service?output_mode=json \
   | jq -r '.[]._key' | grep nwpay_l2_synth_outcomes"

# 2. Smoke test the headline base searches
#    (run inside Splunk Web → Search & Reporting on the demo Splunk Enterprise box)
#      | savedsearch "Indicator - Shared - kbs_te_dx_index"
#      | savedsearch "Indicator - Shared - kbs_te_revenue_at_risk"
#    Both should return 1 row per minute over the last hour.

# 3. Open the glass table
open "https://itsi.splunk-observability.com:8000/en-US/app/itsi/glass_table?key=nwpay_glass_table_overview"
```

If the tiles show "no data", check that `index=thousandeyes` has
recent events (per `scripts/10-extend-itsi-with-te.sh`) and that
the audit log has events in `index=nwpay_audit
sourcetype="nwpay:payment_audit"` (Tier-2 audit pipeline must be
enabled in `helm/natwest-payments/values.yaml`,
`api-gateway.auditEnabled=true`, the default).

## Recovery checklist

If anything goes sideways during the demo:

```bash
scripts/incident.sh recover
kubectl -n natwest rollout status deploy/fraud-detection-service
kubectl -n natwest rollout status deploy/payment-initiation-service
kubectl -n natwest get pods | grep -v Running   # should be empty
```

If the SPA goes blank, hard-refresh; the RUM SDK survives reloads.

If you're driving the demo over `kubectl port-forward` (LoadBalancer was
denied by an SCP) and the local listener dies, restart it with:

```bash
scripts/05a-frontend-portforward.sh
```

then refresh `http://localhost:8080/`.

---

## Pre-flight quick-reference card — C-level top-down cut

Companion to
[`../docs/presentation/EXEC_DEMO_30MIN_TOPDOWN.md`](../docs/presentation/EXEC_DEMO_30MIN_TOPDOWN.md).
Same five beats, terminal-side. Keep this section open in a small
window next to the Glass Table tab.

### One-time, before the room fills (T-15 onwards)

```bash
# Resolve presenter token + SPA URL once; export so every curl below
# inherits them. The chaos-controller secret is what the SPA /ops page
# uses behind the scenes, so the two surfaces stay symmetric.
export CHAOS_PRESENTER_TOKEN="$(kubectl -n natwest get secret \
  chaos-controller-token \
  -o jsonpath='{.data.CHAOS_PRESENTER_TOKEN}' | base64 -d)"
export SPA_URL="$(terraform -chdir=terraform output -raw public_spa_url)"
# Sanity check — should print 200.
curl -fsS -o /dev/null -w '%{http_code}\n' \
  -H "X-Chaos-Token: ${CHAOS_PRESENTER_TOKEN}" \
  "${SPA_URL}/chaos/api/health"
```

### T-15 — arm the SWIFT incident (depth thread)

Preferred path is the SPA `/ops` page — click **Inject** on
`swift-counterparty-flap`. Keyboard fallbacks, in order of preference:

```bash
# A. chaos-controller HTTP API (same audit-event shape as /ops)
curl -fsS -X POST \
  -H "X-Chaos-Token: ${CHAOS_PRESENTER_TOKEN}" \
  -H "Content-Type: application/json" -d '{}' \
  "${SPA_URL}/chaos/api/swift-counterparty-flap/inject" | jq .

# B. legacy CLI (headless / no chaos-controller deployed)
scripts/incident.sh swift-counterparty-flap
```

The `[NatWest demo] SWIFT error rate` detector fires ~3 min later;
the ITSI episode `Payments incident on swift-network` lands shortly
after.

### T-12 — verify the SWIFT episode is visible

```bash
# Quick cluster-side smoke test (1) swift-network has ERROR_RATE set,
# (2) the detector exists in Observability.
kubectl -n natwest set env deploy/swift-network --list \
  | grep -E '^ERROR_RATE='        # expect ERROR_RATE=0.30 (default)

# (Optional) status across every scenario in one shot
curl -fsS -H "X-Chaos-Token: ${CHAOS_PRESENTER_TOKEN}" \
  "${SPA_URL}/chaos/api/scenarios" \
  | jq '.scenarios[] | select(.status.active == true) | {id, status}'
```

Hard-refresh the Overview Glass Table tab; confirm the **Active
payments incident — notable events** panel shows the SWIFT episode.

### T-5 / T-2 — tab order + Presenter HUD

Open tabs left-to-right: (1) Overview Glass Table, (2) ITSI Episode
Review, (3) APM Service Map, (4) RUM Overview, (5) `/ops` Chaos
Dashboard (**last**, so it's not in the tab strip before reveal),
(6) SLOs page.

Then on the secondary screen only:

```
${SPA_URL}/?presenter=1
```

### 0:16 mid-demo — Madrid live inject (breadth thread)

Preferred: click **Inject** on `madrid-network-degradation` on the
`/ops` tab. If the SPA button silently fails (auth blip / network),
back-channel from the keyboard:

```bash
curl -fsS -X POST \
  -H "X-Chaos-Token: ${CHAOS_PRESENTER_TOKEN}" \
  -H "Content-Type: application/json" -d '{}' \
  "${SPA_URL}/chaos/api/madrid-network-degradation/inject" | jq .
```

Detector budget for `[NatWest demo] Madrid p95 latency` is ~3 min,
which lands inside the 0:17–0:21 RUM segment.

### 0:27 — recover everything in one click

While Q&A starts:

```bash
make chaos-recover              # preferred — POST /chaos/api/recover

# Fallbacks
curl -fsS -X POST -H "X-Chaos-Token: ${CHAOS_PRESENTER_TOKEN}" \
  -H "Content-Type: application/json" -d '{}' \
  "${SPA_URL}/chaos/api/recover" | jq .
scripts/incident.sh recover     # headless / chaos-controller offline
```

Confirm baseline:

```bash
scripts/incident.sh status
kubectl -n natwest get pods | grep -v Running   # should be empty
```

> **Symmetry note.** All three paths above
> (`/ops` button, chaos-controller `curl`, `scripts/incident.sh`)
> emit the same-shape `nwpay:chaos` HEC event into `index=nwpay_audit`.
> Whichever path you use, the SIEM correlation searches
> (`chaos_off_change_window`, `payments_excessive_declines_by_tier`)
> still fire — see the header comment in
> [`scripts/incident.sh`](./incident.sh).
