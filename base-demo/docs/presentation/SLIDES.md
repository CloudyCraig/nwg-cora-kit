<!--
NatWest Payment Platform — Splunk Observability Cloud demo deck.

Marp-flavoured Markdown. Render with:

  npx @marp-team/marp-cli@latest SLIDES.md -o slides.pptx
  npx @marp-team/marp-cli@latest SLIDES.md -o slides.pdf
  npx @marp-team/marp-cli@latest SLIDES.md --html

Speaker notes live in HTML comments and travel into PPT/PDF as presenter
notes when exported via Marp. Keep slides bullet-light; the words live in
TALK_TRACK.md.
-->
---
marp: true
theme: default
paginate: true
size: 16:9
header: NatWest Payment Platform · Splunk Observability Cloud
footer: '© 2026 — Demo content. Topology is real, payments are simulated.'
style: |
  section {
    background: #0b1220;
    color: #f3f4f6;
    font-family: 'Inter', 'Helvetica Neue', sans-serif;
  }
  h1, h2, h3 { color: #ffffff; }
  strong { color: #f59e0b; }
  em { color: #38bdf8; font-style: normal; }
  code { background: #1f2937; color: #f59e0b; padding: 2px 6px; border-radius: 4px; }
  section.title { text-align: center; }
  section.title h1 { font-size: 64px; margin-bottom: 0; }
  section.title p { color: #94a3b8; }
  table { font-size: 22px; }
  blockquote { border-left: 4px solid #f59e0b; color: #cbd5e1; }
---

<!-- _class: title -->

# Observability without seams

## NatWest Payment Platform on Splunk Observability Cloud

A live, instrumented payments platform — **24 services, 6 schemes, one
investigation surface**.

<!--
Speaker note:
Open in front of Splunk Observability Cloud, with the SPA loaded in a second
tab and the demo cluster reachable. Don't talk through the title; let it sit
while you frame the room ("a customer just complained their payment is slow")
and pivot into Slide 2.
-->

---

## What you're about to see

| Surface | What it answers |
|---|---|
| **RUM** | "Which customer felt this, and when?" |
| **APM** | "Which service inside the bank slowed them down?" |
| **AlwaysOn Profiling** | "Which line of code is burning the CPU?" |
| **Logs in Context (LOC)** | "Show me this customer's log line, on this trace." |
| **Database Query Performance** | "Which SQL template is dragging settlement?" |
| **Detectors / SLOs / Synthetics** | "Tell me before the customer does." |

> **One trace ID. One investigation. Six product surfaces.** That's the
> story today.

<!--
Speaker note:
This is the Hook Slide. Don't enumerate every row — pick two and tease the
rest. ("RUM ties the customer click to the trace; AlwaysOn Profiling lands on
the line of code. We're going to do the whole walk on one trace ID.")
The capability matrix returns at the end as a bracket.
-->

---

## The platform under the lens

```
Channels (6)        api-gateway           Payment schemes (6)
mobile-app  -->                    -->    Faster Payments  60%
online      -->                    -->    BACS             15%
branch      -->     payment-init   -->    CHAPS             8%
bankline    -->     payment-valid  -->    SEPA              8%
bankline-d  -->     fraud, sanctions->    SWIFT             6%
partner-api -->     routing        -->    Cheque            3%
                    ledger (JVM)    \
                    settlement       --> reconciliation -> reporting
```

- **24 microservices** — auto-instrumented Splunk Distribution of OTel.
  Polyglot: Java `ledger-service`, Python everywhere else.
- **Real data plane** — Postgres for the ledger, Redis for sanctions
  cache, Kafka for settlement fan-out.
- **Realistic shape** — six payment schemes, six channels, country-pair
  spreads, time-of-day RPS curve.
- **Customer tiers** — Bronze / Silver / Gold (Olivia, James, Margaret).
  Tier rides every span as `customer.tier` and drives genuine
  behaviour: Gold gets a fraud-detection fast-path, Bronze is the
  tier the gateway can throttle.

<!--
Speaker note:
Anchor the story in the architecture diagram from the README. Important to
say "real EKS, real Postgres/Redis/Kafka, simulated business logic". This is
the credibility slide — without it, the audience suspects a canned demo.
-->

---

## Act I — A six-minute investigation

> _Tell:_ "A customer just complained their payment is slow. Watch
> what we know in 60 seconds — without asking them anything."

| Step | Surface | Time |
|---|---|---|
| 1. Customer click | **RUM Sessions** | 60s |
| 2. Slow span | **APM Trace** | 75s |
| 3. The log line | **Logs in Context** | 45s |
| 4. The line of code | **AlwaysOn Profiling** | 90s |
| 5. Recover | `incident.sh recover` | 30s |

**One trace ID, end-to-end. RUM → APM → Log → Profile → Commit.**

<!--
Speaker note:
Pre-arm the incident ~3 minutes before stage time:
  scripts/incident.sh fraud-cpu-regression
Run-flow reminder for live sessions:
  scripts/00-provision.sh -> 01-build-push.sh -> 02-install-collector.sh
  -> 03-deploy.sh -> 04-start-traffic.sh -> 05-deploy-frontend.sh
  -> 05b-frontend-public-proxy.sh
That gives AlwaysOn Profiling enough samples to render the diff view.
Don't read the table aloud — point at it as you walk.
-->

---

## Act I · 1 — Customer click  (RUM)

- Open the SPA, submit one **SWIFT** payment. Click feels slower.
- **RUM → Sessions** shows the page action span with `traceparent`
  already attached.
- One click → **APM Trace**.

> _Show:_ "We didn't have to ask the user anything. The SDK tied
> their click to a server-side trace via W3C trace context."

> _Ask Beat:_ "How long does it take your team today to go from
> 'a customer's complaining' to 'I have the trace'?"

<!--
Speaker note:
Common landing time is "20 minutes to an hour" in regulated banks. Use the
silence — wait for someone to answer before moving on. This is the only
moment in Act I where a pause is truly required.
-->

---

## Act I · 2 — Slow span  (APM)

Trace tree: `web-frontend → api-gateway → payment-initiation → fraud-detection`.

- Stop on `fraud-detection-service`. Show:
  - `compute_fraud_features` — CPU-bound child span (the new code)
  - `fraud.algo = pairwise`, `fraud.feature_count = 96` — **business
    attributes**, pivot-able as first-class data
- Sideways glance: `ledger-service` JDBC spans show
  `db.statement = INSERT INTO ledger_entry …`
  → **Database Query Performance** in APM, no Postgres exporter.

> _Tell:_ "We have a hypothesis: fraud-detection. Let's get the log
> line that this code wrote, on this pod, on this trace."

<!--
Speaker note:
DB Query Performance is a free side-quest here. Don't dwell — just point
at the JDBC statements and say "this is its own product surface; we're
coming back to it in Act II."
-->

---

## Act I · 3 — Logs in Context  (APM ↔ Splunk Enterprise)

- Copy `trace_id` from the APM span, pivot to **Logs for this trace**.
- Returns the structured JSON line emitted by `fraud-detection-service`,
  carrying `service`, `level`, `trace_id`, `span_id`, `payment_id`,
  `payment.scheme = SWIFT`.

> _Show:_ "Container logs ship through the Splunk OTel Collector to
> the in-VPC Splunk Enterprise; **Log Observer Connect** federates
> them into Observability Cloud. Same trace ID across the seam."

> _Ask Beat:_ "Where does your trace-ID-to-log-line jump live today —
> and how many tools is that across?"

<!--
Speaker note:
This is the LOC reveal. Visually it's a single click in APM — but the
architectural point matters: the customer's existing Splunk Enterprise
estate becomes the log backplane for o11y. No log re-platform required.
-->

---

## Act I · 4 — Line of code  (AlwaysOn Profiling)

- Same span → **AlwaysOn Profiling → CPU flame graph**.
- Hot stack: `_extract_features_pairwise` inside `compute_fraud_features`.
- **Profiling diff** — last 5 min vs. baseline. The new tower is
  unmistakable.

> _Tell:_ "Continuous profiling, every JVM and Python process, in
> production, ~**1% CPU overhead**. The diff turns a slow trace into
> _the line of code_ — same trace ID, same business context, all the
> way to the stack frame."

<!--
Speaker note:
This is the climax of Act I. Slow down. The flame graph diff is the most
visually dense slide in the demo — give it time. Then run
`scripts/incident.sh recover` to bracket the moment.
-->

---

## Act I · 5 — Recover

```bash
scripts/incident.sh recover
```

- Watch p99 settle. Regression tower disappears from the diff.
- Customer click times return to baseline; SPA feels fast again.

> _Bracket:_ "RUM → Trace → Log → Profile, in six minutes, **on one
> page**. That's what a NatWest engineer's Tuesday afternoon should
> look like."

<!--
Speaker note:
The bracket here lands the Act I narrative. Pause and look at the room
before transitioning to Act II. If you've nailed the room, this is also
where the first real question lands; be ready to absorb a 2-3 minute
discussion before moving to the breadth tour.
-->

---

## Act II · A — Service map  (breadth)

- 24 services auto-discovered from OTel spans alone — no per-service
  tracing PRs.
- **Postgres**, **Redis**, **Kafka** are first-class service nodes,
  not greyed-out inferred icons. The infra-heartbeat CronJob emits one
  synthetic span per minute per backend; the same nodes also carry
  **infrastructure metrics** (memory, evictions, broker latency, pg_stat)
  and pod **logs** in the Related Content tab.
- Polyglot mesh — Java `ledger-service` sitting in the middle of a
  Python fleet, no visual seam.

> _Ask Beat:_ "When was the last time you could actually see your
> payment topology — from a channel click to the scheme leg, with
> the data plane in the same picture?"

<!--
Speaker note:
Click the Postgres node twice: once for DB Query Performance (drives
from postgres_exporter's pg_stat_statements scrape), once for Logs
(filelog receiver auto-tags pod stdout with service.name=postgres).
Same product surface, three entry points (APM, Infra, Logs) - shows
the data model is unified. Repeat with Kafka to land the broker-side
metrics story (request p99, ISR shrinks).
-->

---

## Act II · B — Tag Spotlight  (business questions)

- Pivot `payment-initiation-service` by `payment.scheme`:
  - SWIFT shows highest p99 + error rate
- Pivot by `customer.tier` (**Bronze / Silver / Gold** — Olivia,
  James, Margaret in the SPA persona switcher):
  - **Gold p95 visibly below Bronze** (fraud-detection fast-path)
  - **Bronze decline rate** is the canary the gateway throttle
    detector watches

> _Tell:_ "Every span carries business context. 'Which customer
> tier is hit hardest right now?' is a pivot — not a JIRA ticket
> for the data team. Same dimension on the RUM page span, the API
> span, the JDBC span."

<!--
Speaker note:
This is the differentiator slide for non-technical audiences. The
moment a payments-ops VP sees scheme + segment as first-class
dimensions, the room turns. Linger here longer than the breadth slide.
-->

---

## Act II · C — Detectors, SLOs, Synthetics

```bash
scripts/incident.sh swift-counterparty-flap
```

- **Detectors → Active Alerts**: `[NatWest demo] SWIFT error rate`
  fires Critical within ~30 s.
- Alert detail → threshold band → **runbook URL**.
- **Synthetic Monitoring** chart shows the spike and the recovery.
- **Dashboard "Payments Operations"**:
  RPS by scheme · p99 by scheme · cache hit ratio · GBP volume.

> _Tell:_ "Detectors don't replace your eyes — they buy them back.
> The team sleeps; the platform watches."

<!--
Speaker note:
You can run swift-counterparty-flap mid-presentation; it lands in ~30s
which is plenty of time to walk through dashboards while it propagates.
-->

---

## Act II · D — Infra metrics & ITSI roll-up

- **Splunk Observability ➜ Infrastructure**: Redis / Postgres / Kafka
  navigators auto-populate the moment the collector lights up. Memory,
  evictions, broker latency, replication health, query stats — no
  hand-rolled SignalFx integration, no Prometheus federation.
- **Splunk ITSI ➜ Service Analyzer**: same metrics drive `nwpay_l4_redis`
  / `nwpay_l4_postgres` / `nwpay_l4_kafka` health scores. A red L4 node
  flows up to the L3 microservice that depends on it, and onward into
  Auth / Booking / Settlement at L2.
- **One walk to prove it**: kill the Redis pod →
  - APM service map: Redis goes red.
  - Infra navigator: evictions/memory drop to zero.
  - ITSI: nwpay_l4_redis turns Critical, Auth weighted-avg score
    drops, sanctions cache miss KPI flips warning.
  - Detector "Redis evictions / memory" fires within 2 min.

> _Tell:_ "The same data plane that pinpointed a single slow span on
> SWIFT is now answering 'is the broker healthy?' in the same UI, with
> the same dimensions. Application teams and SRE share the picture."

<!--
Speaker note:
This is the slide that bridges APM-only customers (most prospects) into
the wider Splunk Observability + ITSI message. Demo move: click the
nwpay_l4_kafka health tile, then click "Show in service map" — same
node both sides. Optional chaos: kubectl delete pod redis -n natwest;
within 2 min you'll see a textbook propagate.
-->

---

## Act II · E — Synthetic monitoring & Digital Customer Experience

- **ThousandEyes ➜ Splunk via the Cisco add-on**: 6 synthetic tests
  hitting `itsi.splunk-observability.com` every 2-15 minutes from 5
  geos. HTTP availability, real-browser page-load, full payment
  journey via Selenium, DNS resolution, and a direct
  `POST /api/process` write probe.
- **ITSI L2 "Digital Customer Experience" tier**: 7 synthetic KPIs
  feeding `nwpay_l2_dce`, weighted into the same `nwpay_l1` health
  score as Auth / Routing / Booking / Settlement.
- **The story it lets you tell**:
  - Red RUM tile + green DCE tile → real-user latency, not the bank
    being broken (probably ISP-side, push the conversation).
  - Green RUM tile + red DCE tile → we hear about this from a
    synthetic check before any real customer notices, ahead of the
    P1 bridge call.
  - Both red → drill into the failing TE test from the L2 tile and
    pivot straight to the `index=thousandeyes` event for the failing
    round, with agent IPs and path-trace ready for the network team.

> _Tell:_ "The customer experience tier is now driven by data we
> control, on a schedule we control, from places we choose. That's
> the foundation an SLO hangs off — not 'we got an email from a
> customer'."

<!--
Speaker note:
Optional Act II.E for ITSI-mature audiences. Skip when the room is
green-field. Demo move: open the L1 service analyzer, click into
"Digital Customer Experience", show the 7 KPIs and the
`index=thousandeyes` drilldown. If TE is mid-bootstrap and only
some KPIs have data, lean into "ITSI shows you 'no data' explicitly
- it never silently green-tiles a missing signal".
-->

---

## Splunk's edge — what you saw

| Strength | Where it landed |
|---|---|
| **Cross-domain correlation** | RUM click → APM trace → log → profile, **same trace ID** |
| **Auto-instrumentation breadth** | 24 services, polyglot, zero per-service PRs |
| **AlwaysOn Profiling** | Line of code, in production, ~1% overhead |
| **Business attributes as data** | `payment.scheme`, `customer.tier` (Bronze/Silver/Gold) pivot-able |
| **Database Query Performance** | Postgres slow-query bucketing, no exporter |
| **LOC bridge** | Existing Splunk Enterprise estate is the log backplane |
| **Detectors + SLOs + Synthetics** | Same data plane, same dimensions |
| **ThousandEyes synthetic + ITSI** | Customer-experience tier in ITSI driven by 6 TE tests, 7 KPIs |

<!--
Speaker note:
This is the recap — visually identical to the Slide 2 capability matrix
but populated with the things they just watched happen. Bracket the
opening; do not introduce new capabilities here.
-->

---

## Why this matters for NatWest

- **Mean time to context** collapses — minutes, not change tickets
- **Single backplane** — RUM, APM, Profiling, Logs, Synthetics, Infra
  all share the same dimensions and the same trace IDs
- **Existing Splunk estate is reused** — LOC means logs stay where
  they are, governance untouched
- **Polyglot is a non-event** — Java + Python, and any future Go
  or .NET service joins for free
- **Business-first attributes** — payments-ops, fraud-ops, and
  engineering all read the same screen

<!--
Speaker note:
This is the executive landing. Address the CTO/CIO/COO line directly.
Resist the urge to talk about cost — the moment you do, the conversation
turns into a procurement workshop.
-->

---

## Common objections

| "..." | Anchor in what you just saw |
|---|---|
| "We have ELK / Datadog / Dynatrace already." | Same trace ID end-to-end, business attributes first-class, LOC keeps existing log estate. |
| "Profiling will drown my CPU budget." | ~1% overhead, AlwaysOn samples continuously, you saw the diff land. |
| "We can't roll OTel across 24 services." | You already did — every service in this demo was instrumented by deployment alone. |
| "Logs and traces are different tools." | Same `trace_id` field, federated via LOC into Splunk Enterprise. One click in APM. |
| "Our payments are too sensitive." | Tags carry the dimensions you choose; PII never has to leave the service boundary. |

<!--
Speaker note:
Keep this slide on screen for objection cycling. If a question maps to
a row, answer using the panel they saw — never abstract.
-->

---

## Next step

> Champion brief — paste-ready

> The NatWest Payment Platform demo runs an EKS-hosted, 24-service
> simulation of our payment topology — **mobile/branch through to
> SWIFT/CHAPS/FPS/BACS/SEPA/Cheque** — fully instrumented with the
> Splunk Distribution of OpenTelemetry. In **6 minutes** Splunk
> Observability Cloud takes a customer's slow click in RUM, follows
> the trace into the API gateway, identifies the regressed service,
> opens the **structured log line** for that exact request via Log
> Observer Connect, and lands on the **regressed line of code** in
> AlwaysOn Profiling — with `~1% CPU overhead` in production. The
> live cluster is running in the same VPC as our existing Splunk
> Enterprise; no log re-platform required.

**Ask:** "Let's schedule a 60-minute technical deep-dive with your
SRE / payments-ops leads against your real services."

<!--
Speaker note:
Read the champion brief aloud once - it's the paragraph you want them
to forward internally. Then pivot to the 60-minute follow-up ask.
Don't pitch licensing; that's a separate motion.
-->

---

## Access details (operator quick links)

| Surface | URL | Access |
|---|---|---|
| **Splunk ITSI / Splunk Web** | `https://itsi.splunk-observability.com:8000/en-US/app/itsi` | `admin` + `TF_VAR_splunk_enterprise_admin_password` (demo default may be `smartway`) |
| **Splunk Observability Cloud** | `https://app.<realm>.signalfx.com` | Splunk Cloud org sign-in (SSO/local) |
| **Realm / ingest token** | Terraform input | `TF_VAR_splunk_realm`, `TF_VAR_splunk_access_token` |
| **Detector/dashboard provisioning token** | Terraform input | `TF_VAR_splunk_api_token` |

> **Demo note:** keep credentials out of slides; use environment variables
> and org SSO for live access.

<!--
Speaker note:
This slide is operational framing, not a sales moment. Keep it to
20-30 seconds and move to Q&A.
-->

---

<!-- _class: title -->

# Thank you

Splunk ITSI / Splunk Web — `https://itsi.splunk-observability.com:8000`
Splunk Observability Cloud — `https://app.<realm>.signalfx.com`

Champion contact: `<your name and email>`

<!--
Speaker note:
Hold this slide while Q&A continues. If asked for the Splunk Enterprise
login: admin / smartway, restricted to the operator IPs in the SG.
-->
