# NatWest Payment Platform — Demo talk track

**Duration profiles:** 30 / 45 / 60 min (pick one before you start)
**Surfaces:** Splunk Observability Cloud (RUM, APM, AlwaysOn Profiling,
Detectors, Synthetics, Dashboards) + Splunk Enterprise via Log Observer
Connect.
**Narrative in one line:** A customer just complained their payment is
slow — six minutes later, you're on the regressed line of code, with
the customer's log line in your hand.

> Companion artefacts:
>
> - `docs/presentation/SLIDES.md` — Marp deck (Acts I & II)
> - `scripts/run-of-show.md` — operational drive script (commands,
> cluster checks, recovery)
> - `README.md` (top level) — install / verify / cost

---

## Pre-demo checklist

- All `00-..05-` provisioning scripts have run; `kubectl get pods -n natwest` is green for all 24 services.
- Splunk Observability Cloud open in browser tab 1, scoped to
`environment=demo`, `cluster=natwest-payments-demo`.
- SPA open in tab 2 (`web-frontend` ELB or `localhost:8080` via
`scripts/05a-frontend-portforward.sh`).
- Terminal 3 with `kubectl` configured + `scripts/incident.sh status` printing all defaults.
- **3 minutes before stage:** `scripts/incident.sh fraud-cpu-regression`. AlwaysOn Profiling needs the time to
sample both baselines; don't skip this.
- If using public demo URL, confirm
`scripts/05b-frontend-public-proxy.sh` has been run for this stack.
- Slack / phone on Do Not Disturb. The demo ticker is the only
thing that should move.

---

## Runtime cuts (30 / 45 / 60)

Use the same narrative each time; only trim or expand optional beats.


| Segment                           | 30 min | 45 min | 60 min  |
| --------------------------------- | ------ | ------ | ------- |
| Frame + architecture (Slides 1-3) | 3 min  | 5 min  | 7 min   |
| Act I (I.1 -> I.5)                | 8 min  | 10 min | 12 min  |
| Act II core (II.A -> II.D)        | 12 min | 18 min | 24 min  |
| Optional deep-dive beats          | skip   | 6 min  | 12 min  |
| Closing + objections + next step  | 4 min  | 4 min  | 5 min   |
| Q&A buffer                        | 3 min  | 2 min  | 0-3 min |


**What to include by profile**


| Profile    | Keep                                                     | Skip / Optional                                            |
| ---------- | -------------------------------------------------------- | ---------------------------------------------------------- |
| **30 min** | Act I full, II.A, II.B, II.C, short II.D, close          | Skip II.A.1 / II.B.1 / II.B.2 / II.C.1 / II.C.1.1 / II.C.2 |
| **45 min** | 30-min core + II.B.1 + II.C.1                            | II.B.2 and II.C.1.1 optional based on audience             |
| **60 min** | 45-min flow + architecture aside + network/AIOps options | Only skip pieces that are not available in tenant          |


---

## Audience


| Role                                    | What they care about                                | Land on                                              |
| --------------------------------------- | --------------------------------------------------- | ---------------------------------------------------- |
| **CTO / CIO**                           | Mean time to context; one backplane, not five       | Slide 14 (Why this matters) + Act I.4 (line of code) |
| **VP Payments / Ops**                   | Customer-facing latency; scheme-level risk          | Act II.B (Tag Spotlight: scheme + segment)           |
| **Head of SRE / Observability**         | Polyglot OTel adoption, CPU overhead, alert fatigue | Act I (full trace) + Act II.C (Detectors / SLOs)     |
| **Head of Platform Security**           | PII exposure on attributes; log data residency      | Objections 4 & 5; LOC slide (Act I.3)                |
| **Splunk champion (existing customer)** | "Reuse my Splunk Enterprise estate"                 | LOC slide (Act I.3); Champion brief                  |


---

## Act I — The 6-minute investigation

The whole arc rides on a single trace ID.
**Tell-Show-Tell** with one Ask Beat in each step.

### I.1 — Customer click (Splunk RUM) · 60s

**Opening Tell.** "I want you to imagine the call your support desk
gets every day. A customer says 'my payment is slow' and your job is
to figure out what they mean — fast — without asking them for a
screenshot, a payment ID, or a reference number."

**Show.**

- Open the SPA, submit one **SWIFT** payment.
- Switch to **RUM → Sessions**, open the session you just made.
- Highlight the page-action span for `Send payment`. Point at
`traceparent` — the SDK has already linked the click to a
server-side trace via W3C trace context.
- Click **APM trace** from the RUM span.

**Closing Tell.** "Forty-seven seconds ago this customer pressed
Send. They saw a 1.4-second wait. We never asked them anything; the
SDK handed us the trace."

> **Ask Beat:** *"How long does it take your team today to go from
> 'a customer is complaining' to 'I have the trace'?"*
> Pause. Wait for an answer.

### I.2 — Slow span (Splunk APM) · 75s

**Tell.** "Now we know who, and we know when. The trace tells us
who's actually slow."

**Show.**

- Walk down the trace tree:
`web-frontend → api-gateway → payment-initiation → fraud-detection`.
- Stop on `fraud-detection-service`. Surface:
  - `compute_fraud_features` — the new CPU-bound child span.
  - `fraud.algo = pairwise`, `fraud.feature_count = 96` —
  **business attributes** as first-class data.
  - Span duration dominates the trace.
- Side-quest: scroll to `ledger-service` JDBC spans. Point at
`db.system = postgresql`, `db.statement = INSERT INTO ledger_entry`,
`SELECT SUM(amount_minor)`. Tease **DB Query Performance**.

**Closing Tell.** "Slow is fraud-detection. Hypothesis live. Now I
want the log line that this code wrote, on this pod, on this
trace."

> **Ask Beat:** *"How many tools is that journey today —
> RUM, trace, log? Two? Three? Five?"*

### I.3 — Logs in Context (LOC) · 45s

**Tell.** "We don't want every log line in the platform. We want
**this customer's** log line, on **this trace**, on **this pod**."

**Show.**

- Same span. Click **Logs for this trace**.
- The structured JSON record from `fraud-detection-service` returns:
`service`, `level`, `trace_id`, `span_id`, `payment_id`,
`payment.scheme = SWIFT`.
- Architecture moment: container logs ship via the Splunk OTel
Collector to the **in-VPC Splunk Enterprise** instance (port 8088
HEC); LOC federates them into Observability Cloud. **The customer's
existing Splunk estate is the log backplane** — no log
re-platform.

**Closing Tell.** "Same trace ID across the seam. Your existing
Splunk Enterprise becomes the log surface for o11y."

> **Ask Beat:** *"Where does that pivot live in your stack today —
> and how many context switches does it cost an SRE on call at
> 03:00?"*

### I.4 — Line of code (AlwaysOn Profiling) · 90s

**Tell.** "We've narrowed it to a service and a single span.
Production code regressions don't tell you why. Profiling does."

**Show.**

- Same APM span → expand **AlwaysOn Profiling**.
- Open **CPU flame graph**. Hot stack:
`_extract_features_pairwise` inside `compute_fraud_features`.
- Switch to **Profiling diff**, last 5 min vs. baseline.
- The new tower is unmistakable. The frame name is the line of code.

**Closing Tell.** "AlwaysOn Profiling samples every JVM and Python
process in production, all the time, ~**1% CPU overhead**. The diff
is what makes a slow trace actionable — not 'fraud-detection
regressed' but **which line of which file** regressed it."

> **Ask Beat:** *"How often, today, does an investigation actually
> finish on a line of code — not a hunch?"*

### I.5 — Recover · 30s

**Show.**

```bash
scripts/incident.sh recover
```

- Watch p99 settle in the dashboard pane.
- Refresh the SPA: next payment goes through fast.
- Profiling diff: regression tower disappears.

**Bracket.** "RUM → Trace → Log → Profile, in six minutes, **on
one page**. Same data plane, same dimensions, same trace ID. That's
what a NatWest engineer's Tuesday afternoon should look like."

> **Pause.** This is where the first real question lands. Absorb
> 2–3 minutes of discussion before moving to Act II.

---

## Act II — The breadth tour (~12 minutes)

Now that the audience has watched **one** investigation, walk them
through the rest of the platform's reach. Keep each step short — the
heavy lifting is done.

### II.A — Service map · 3 min

**Show.**

- **APM → Service Map**, scoped to `environment=demo`.
- 24 services auto-discovered.
- Inferred **Postgres**, **Redis**, **Kafka** nodes. The dotted
Kafka edge between `payment-initiation` and `settlement` is the
async producer→consumer signal — not magic, just OTel.
- Polyglot mesh — Java `ledger-service` middle-of-fleet, Python
everywhere else, no visual seam.
- Click the Postgres node → DB Query Performance from the infra
view (same surface as the side-quest in Act I.2, different entry).

> **Ask Beat:** *"When was the last time you saw your payments
> topology like this — channel through scheme, with the data plane
> in the same picture?"*

### II.A.1 — Mobile channel parity (optional, 1 min)

Open a second browser tab to the same SPA URL with `?app=mobile`
appended. The page renders inside a phone-shaped frame with a
distinct RUM application name (`natwest-payments-mobile`) and a
`channel=mobile` global attribute on every span.

Pivot back to **RUM → Applications**: two app tiles now exist for
the same demo (`natwest-payments-web` and `natwest-payments-mobile`).
Open Tag Spotlight on `api-gateway` and pivot by `channel` —
mobile and web sessions show as distinct cohorts on the same
service map node, with the same trace IDs flowing into APM.

> **Talk track:** "Same backend, two channels, one observability
> picture. The minute you ship a real Android or iOS app on
> @splunk/otel-android, it joins this view as a third application
> tile — no infrastructure change required."

### II.B — Tag Spotlight · 3 min

**Show.**

- **APM → Tag Spotlight** for `payment-initiation-service`, last
hour.
- Pivot by `payment.scheme` — SWIFT has the highest p99 + error
rate.
- Pivot by `customer.tier` — Bronze, Silver, Gold (Olivia / James /
Margaret in the SPA persona switcher). Gold p95 sits visibly below
Bronze because the fraud-detection service skips its heavy kernel
on the Gold fast-path; Bronze decline rate is the canary the
`[NatWest demo] Bronze tier decline rate` detector watches.
- Pivot by `country_pair` — operational pain has a geographic shape.

**Tell.** "Every span carries business context. 'Which customer
tier is hit hardest right now?' is a pivot, not a JIRA ticket for the
data team — and the same dimension is on the RUM page-load span,
the API span, the database span, all the way through."

> **Ask Beat:** *"If your VP of Payments asked you 'which scheme is
> hurting which customer tier right now', how long would it take
> you to answer?"*

### II.B.1 — APM trace waterfall (optional, 90 s)

**Show.**

- **APM → Traces** for `payment-initiation-service`, sorted by
duration descending. Pick the top trace.
- Open the waterfall view. Walk top-down:
  - api-gateway → payment-initiation (parent span ~ 1.2 s).
  - payment-initiation fan-out: sanctions-aml, fraud-detection,
  customer-profile, ledger. Tail latency is concentrated in
  sanctions-aml (gold-tier story).
  - One Postgres span on ledger-service shows up under the
  db.system=postgresql node — that's the row that drives the
  "auto-detected database service" beat in the next section.
- Right-click the slowest span → **Logs in Context**. Same pivot as
I.3 but starting from a span instead of a service.

**Tell.** "Service maps tell you *which* service is unhealthy. The
waterfall tells you *which call* inside that service is unhealthy.
Both views, same data, no copy-paste between tools."

### II.B.2 — AI Assistant in Splunk Observability (optional, 60 s)

Only run this beat if the customer's tenant has the AI Assistant
feature enabled (Cisco AI Assistant for Splunk Observability — GA
since 2025). If the side-panel "Ask the assistant" affordance is
missing in the APM view, skip this beat silently.

**Show.**

- From the APM service map, open the **Ask the assistant**
side-panel.
- Ask: *"Why is payment-initiation-service slow over the last 15
minutes?"*
- The assistant returns a structured answer: pinpoints sanctions-aml
tail-latency, cites the affected traces, and suggests the
burn-rate detector that already fired.
- Follow-up: *"Summarise the open ITSI Episodes for the payments
domain."*

**Tell.** "We're not asking the assistant to operate the platform.
We're asking it to do the boring 30 seconds of correlation that
sits between 'something is wrong' and 'I know what's wrong'. That's
the only AI claim we'll make on stage today — everything else is
deterministic telemetry."

### II.C — Detectors + SLOs + Synthetics · 3 min

**Show.**

```bash
scripts/incident.sh swift-counterparty-flap
```

- **Detectors → Active Alerts**: `[NatWest demo] SWIFT error rate`
fires Critical within ~30 s.
- Click through: alert detail → threshold band → runbook URL.
- **Synthetic Monitoring → `[NatWest demo] payments gateway`** —
per-minute results show the spike and the recovery.
- Optional: cycle one of `incident.sh cache-cold` / `db-slow` to
show the catalogue of failure modes.

**Tell.** "Detectors don't replace your eyes — they buy them back.
The team sleeps; the platform watches."

### II.C.1 — Closed-loop ticketing (optional, 1 min)

**Show.**

- ITSI Episode Review still has the Episode from `swift-counterparty-flap`.
- Open the **NatWest payments overview** glass table → **Active
incidents in ServiceNow** tile shows the ticket count tick up.
- Open the simulator dashboard
(`kubectl -n natwest port-forward svc/snow-simulator 8080:8080`
→ [http://localhost:8080](http://localhost:8080)) and show the new INC ticket — title,
service, severity all carry through from the Splunk Observability
detector.

**Tell.** "Detection that doesn't open a ticket is just a beep. The
ITSI Episode fires, the alert bridge POSTs to ServiceNow, the on-call
engineer gets a normal ITSM workflow — same one they use for every
other incident. We're closing the loop, not adding another tool."

### II.C.1.1 — AIOps log clustering (optional, 60 s)

**Show.**

- Open **Splunk Cloud → Apps → AIOps Insights → Log clustering**
(or, on-prem, the **Smart Log Reduction** view in ITSI).
- Scope to `index=main` over the last 24 h. Splunk groups the
thousands of raw error lines into ~15 archetypal clusters.
- Filter for clusters with `change_indicator > 0` (anomalous /
novel patterns). Highlight the one matching
`payment-validation-service` schema-drift errors that appeared
during the last `incident.sh validation-error-spike` run.
- Pivot from the cluster → "Show events" → "Logs in Context" so
the audience sees the same workflow they saw in Act I, but
starting from a *cluster* instead of a known service.

**Tell.** "When you don't know which log to look at, the platform
groups them for you. We're not asking the operator to read 10,000
log lines. We're asking them to read 12 cluster summaries — and
the platform tells them which 1 is new today."

### II.C.2 — WAN & BGP path visibility (optional, 1 min)

**Show.**

- Scroll to the **WAN & BGP path visibility** strip on the
glass table:
  - **Network loss %** by agent — quiet today, spike during
  `inject-network-loss eu-west`.
  - **Network latency ms** by agent — Singapore vs Frankfurt vs NYC
  sit at the expected envelope.
  - **Upstream ASNs traversed** — how many distinct AS hops the
  customer's bytes pass through end-to-end.
  - **BGP route changes (24h)** — instability counter; flips amber
  if more than 2 path changes happen in a day.
- Click **Open Path Visualization in ThousandEyes →** to drill into
the topology view (full hop-by-hop traceroute with AS overlays).

**Tell.** "When a payment fails, the first question is always 'is it
us or is it the internet?'. ThousandEyes tells you the difference
*before* the customer call lands."

### II.C.3 — Synthetic business outcomes · 1 min

**Show.**

- Scroll to the **Synthetic-driven business view** strip — same
ThousandEyes tests, expressed in customer / revenue / SLO terms:
  - **Digital Experience Index (last 1h)** — single 0-100 number
  blending SPA availability, API gateway availability, end-to-end
  journey success, page-load Apdex and DNS. The Head of Digital's
  one-tile health check.
  - **GBP at risk / minute** — synthetic failure rate × audited GBP
  baseline. "If our canary is right, this is what's leaving the door
  every minute we don't fix this."
  - **Customers blocked / minute** — same factor on distinct customer
  count, so the support desk can predict call volume.
  - **Synthetic outage minutes (last 1h)** — feeds straight into SLA
  reporting.
  - **Reachability by region (EMEA / NA / APAC)** — sometimes the
  bank is up from London but down from Singapore. This is the only
  tile that catches that.
  - **SLO 1h fast-burn (99.9% journey SLO)** — Google SRE multi-window:
  >14.4 means 2% of the monthly error budget burned in the last hour
  → page now.
- Drill into ITSI service tree → **Synthetic Business Outcomes** for
the matching KPIs (DX Index, Journey Apdex T 20s / F 60s, SLO 1h/6h
burn, GBP at risk, customers blocked, geo reachability).

**Tell.** "Synthetic monitoring used to be 'is the page up?' These
tiles answer 'how much business are we losing right now?' — same
six probes, but read by a CFO instead of an SRE. The audit log gives
us the GBP-per-minute baseline so the number stays meaningful even
at 03:00 when there's no live traffic to compare against."

### II.D — Dashboard · 3 min

**Show.**

- **Dashboards → `[NatWest demo] Payments Operations`**:
  - **RPS by scheme** — the time-of-day curve.
  - **p99 latency by scheme** — SWIFT and CHAPS lead, FPS dominates
  volume.
  - **Cache hit ratio** — dips during `cache-cold`.
  - **GBP volume processed** — the VP-of-Payments single number.
  - **p95 latency by customer tier** — Gold visibly below Bronze
  (fraud fast-path).
  - **Decline + throttle rate by customer tier** — flips Bronze
  during `inject-tier-throttle bronze`; Silver and Gold stay flat.
  - **Customer tier mix** — live snapshot of who's hitting the
  gateway right now.
- Run `scripts/incident.sh recover`. Numbers heal in real time.

---

## Closing — bracket the hook

Return to Slide 2 (or to the APM dependency view).

> "RUM, APM, Profiling, Logs, Detectors, Synthetics, Dashboard —
> all share the same data plane, the same dimensions, the same
> trace IDs. **One mental model. One place every signal converges
> into a story.** That investigation in the first six minutes is
> what good looks like, every day."

**Next step.** "I want to spend 60 minutes against your real
services with your SRE and payments-ops leads. We'll bring the
collector config; you bring two services. By the end of the hour,
they're on the service map."

---

## Objection handling


| Objection                                                                  | Response anchored in the demo                                                                                                                                                                                                                                               |
| -------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **"We already have ELK / Datadog / Dynatrace."**                           | "What you saw today wasn't a log search; it was a **trace ID** linking RUM → APM → log → profile across one investigation. Show me where that single trace ID lives in your current toolchain."                                                                             |
| **"AlwaysOn Profiling will eat my CPU budget."**                           | "The cluster you saw is running it on every JVM and Python process **right now**, in this room, for ~1% overhead. Look at the dashboard panels — no anomalous CPU."                                                                                                         |
| **"Rolling OpenTelemetry across 24 services is a multi-quarter program."** | "We deployed those 24 services and walked away. The Splunk Distribution of OTel auto-instruments at the language level — Python and Java services in this demo got tracing without a single PR."                                                                            |
| **"We can't expose PII as span attributes."**                              | "Tags are dimensions you opt into. `payment_id` is a UUID, `customer.id` is a stable surrogate (`cust-uk-001`), `customer.tier` is a Bronze/Silver/Gold category, `payment.scheme` is a code. There is no PAN, no name, no PII in any span we showed."                      |
| **"Our log estate is on Splunk Enterprise; we can't move it."**            | "You don't move it. **Log Observer Connect** federates your existing Splunk Enterprise into Observability Cloud — that's the link you saw in Act I.3. Same governance, same retention, same indexers."                                                                      |
| **"How does this differ from APM tools that already do tracing?"**         | "Three things you saw: (1) the **profiling diff** landing on a line of code, (2) **business attributes** like `payment.scheme` as first-class pivots, (3) the **infra inference** for Postgres / Redis / Kafka without exporters. Those are not table-stakes APM features." |
| **"What about cost — what's per-span, per-host pricing?"**                 | "Happy to walk through that with your AE on a separate motion. The architecture choice doesn't change with the licensing model — what you saw today is the technical capability, decoupled."                                                                                |


---

## Competitive positioning

Default intensity is **Woven** — narrate the strengths, never name
competitor weaknesses. Switch to **Called Out** in Act II.A if a
prospect has named the alternative; switch to **Head-to-head** only
when explicitly invited.


| Context                               | Splunk strength                                              | Where it landed        | Presenter cue                                                                                           |
| ------------------------------------- | ------------------------------------------------------------ | ---------------------- | ------------------------------------------------------------------------------------------------------- |
| "We use [APM-only vendor]."           | RUM ↔ APM ↔ Profiling ↔ Logs on one trace ID                 | Act I.1 → I.4          | "Watch the trace ID survive every product surface. That's the integration story."                       |
| "We use a logging-only platform."     | Trace context in every log line; LOC bridge                  | Act I.3                | "Logs alone never told you which line of code. Logs *with* trace IDs and a profiler do."                |
| "We have an in-house ELK/Loki/etc."   | OTel-native ingest; no parsers; data plane reuse             | Act II.A (service map) | "We didn't build that mesh; we deployed services and walked away."                                      |
| "[Competitor] also profiles."         | Always-on (not on-demand), continuous diffs, ~1% overhead    | Act I.4                | "Profiling diff vs. baseline is what made fraud-detection actionable. That diff isn't a snapshot tool." |
| "[Competitor] also auto-instruments." | Polyglot (Java + Python here) on one map; no per-service PRs | Act II.A               | "24 services, two languages, one click to discovery. Polyglot was a non-event."                         |
| Splunk-incumbent                      | LOC reuse of existing Splunk Enterprise estate               | Act I.3                | "Your existing Splunk indexers are the o11y log backplane already — no migration."                      |


---

## Champion brief — paste-ready

> **NatWest Payment Platform — live Splunk Observability Cloud demo**
>
> Runs an EKS-hosted, 24-service simulation of our payment topology
> (mobile / online / branch / bankline / partner-api against
> FPS / BACS / CHAPS / SEPA / SWIFT / Cheque), fully instrumented with
> the Splunk Distribution of OpenTelemetry. In **6 minutes**, Splunk
> Observability Cloud takes a customer's slow click in **RUM**, follows
> the trace through the API gateway, identifies the regressed service
> in **APM**, opens the structured log line for that exact request via
> **Log Observer Connect** to our existing Splunk Enterprise, and
> lands on the **regressed line of code** in **AlwaysOn Profiling** —
> with ~1% CPU overhead in production. The demo also covers the
> **service map** (24 services, polyglot, inferred Postgres / Redis /
> Kafka), **Tag Spotlight** business pivots (`payment.scheme`,
> `customer.tier` — Bronze / Silver / Gold), and **Detectors /
> Synthetics / SLOs** (including a Bronze-tier decline detector
> that fires when the gateway throttles low-tier traffic).
>
> The cluster is in the same VPC as our Splunk Enterprise instance —
> no log re-platform required.
>
> **Splunk Web:** `http://itsi.splunk-observability.com:8000` (admin / smartway,
> SG-restricted to operator IPs)
> **Splunk Observability Cloud:** realm `<ours>`, environment
> `demo`, cluster `natwest-payments-demo`
> **Recovery script:** `scripts/incident.sh recover`
> **Run-of-show:** `scripts/run-of-show.md`

---

## Recovery & failure modes

If the demo wobbles mid-flight:

```bash
scripts/incident.sh recover
kubectl -n natwest rollout status deploy/fraud-detection-service
kubectl -n natwest rollout status deploy/payment-initiation-service
kubectl -n natwest get pods | grep -v Running   # should be empty
```


| Symptom                                                    | Fix                                                                                                                                                      |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| SPA blank                                                  | Hard-refresh; the RUM SDK survives reloads.                                                                                                              |
| Service Map missing nodes                                  | Wait 60–90 s; the cluster receiver flushes on a 30 s tick.                                                                                               |
| LB pending (`SyncLoadBalancerFailed`)                      | Org SCP blocks `CreateLoadBalancer`. Run `scripts/05a-frontend-portforward.sh` and demo on `localhost:8080`. RUM still ships to o11y over public ingest. |
| Splunk Enterprise unreachable                              | Operator IP changed. Add `/32` to the SG via `aws ec2 authorize-security-group-ingress` or update `splunk_enterprise_web_allowed_cidrs` and re-apply.    |
| `incident.sh fraud-cpu-regression` not visible in profiler | Wait 60–120 s; AlwaysOn samples on a slow tick, the diff view needs ~2 minutes of post-regression samples.                                               |


---

## Pacing reference


| Block                                                           | 30 min | 45 min | 60 min |
| --------------------------------------------------------------- | ------ | ------ | ------ |
| Slides 1–3 (frame + architecture)                               | 3      | 5      | 7      |
| Act I (full investigation)                                      | 8      | 10     | 12     |
| Act II.A (service map)                                          | 3      | 4      | 5      |
| Act II.B (Tag Spotlight)                                        | 3      | 4      | 5      |
| Act II.C (Detectors/SLOs/Synthetics)                            | 3      | 4      | 5      |
| Act II.D (Dashboard)                                            | 2      | 3      | 4      |
| Optional beats (mobile, waterfall, AI, closed-loop, AIOps, WAN) | 0      | 6      | 12     |
| Why / Objections / Champion / Next step                         | 4      | 4      | 5      |
| Q&A buffer                                                      | 4      | 5      | 5      |


