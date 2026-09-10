# NatWest Payment Platform — slide-aligned demo talk track

**Companion to:** [`natwest-splunk-demo.pptx`](./natwest-splunk-demo.pptx)
(rendered from `splunk-deck-2026.pptx` via `build_pptx.py`)
**Default runtime:** 45 minutes (works at 30 / 60 — see Pacing).
**Surfaces in play:** Splunk Observability Cloud (RUM, APM, AlwaysOn
Profiling, Logs in Context, Detectors, Synthetics), Splunk Enterprise +
ITSI, ThousandEyes, the Chaos Controller in the SPA.

> If you have only one minute to read this file before stepping on stage,
> read **Pre-flight checklist** and **Slide 11 (Recover)**. Everything else
> is muscle memory.

---

## Pre-flight checklist (run T-15 minutes)

```bash
# Cluster green
kubectl -n natwest get pods | grep -v Running   # should print nothing
scripts/incident.sh status                      # all defaults

# Pre-warm AlwaysOn Profiling baseline — needs ~2 min of "good" samples
# before the diff view becomes legible after Act I.4. Don't skip this.
scripts/incident.sh fraud-cpu-regression
sleep 180
scripts/incident.sh recover                     # then let it idle for 2 min

# Optional: warm the European story
#   • Pre-arm the Madrid p95 detector so the audience sees the baseline
#     line. Don't inject yet — the chaos lever is the surprise.
```

**One-time per tenant (skip if already done):** the demo's
`customer.tier`, `customer.location`, `payment.scheme`, `payment.roaming`
and friends only appear in **Service Map → Breakdown** and **Tag
Spotlight** if you've promoted them to APM MetricSets. If today is the
first time this tenant has seen the demo:

```bash
# Best-effort API attempt + manual UI fallback. Either path takes ~5 min.
SPLUNK_REALM=... SPLUNK_API_TOKEN=... scripts/05d-promote-metricsets.sh
```

Full instructions and the canonical list of 9 MetricSets:
[`docs/operations/metricsets.md`](../operations/metricsets.md).

Tabs ready:

1. **Splunk Observability Cloud** — `environment=demo`, `cluster=natwest-payments-demo`.
2. **SPA** — `http://<frontend-elb>/` (Home page, persona selector visible).
3. **SPA · /ops** — Chaos Controller tab, presenter token already pasted.
4. **ITSI** — `natwest-payments-overview` glass table.
5. **Terminal** — `kubectl` configured, `scripts/incident.sh status` last on-screen.

Slack / phone on Do Not Disturb. The demo ticker is the only thing that
should move.

---

## Audience anchors

Most rooms are mixed. Pick the cue that matches the loudest persona.

| Role                              | Land on                                              | Slide |
| --------------------------------- | ---------------------------------------------------- | ----- |
| CTO / CIO                         | Mean time to context; one backplane, not five        | 3, 19 |
| VP Payments / Ops                 | Customer-facing latency; scheme + tier + geography   | 14, 16, 17 |
| Head of SRE / Observability       | Polyglot OTel, ~1 % profiling overhead, alert fatigue | 7–11, 15 |
| Platform Security                 | PII opt-in on attributes; log data residency         | 9, 20 |
| Splunk-incumbent                  | "Reuse my Splunk Enterprise"                         | 9, 16 |

---

## Pacing reference

| Segment                                   | 30 min | 45 min | 60 min |
| ----------------------------------------- | -----: | -----: | -----: |
| Slides 1–5 (frame + capability matrix)    |    3   |    5   |    7   |
| Act I (Slides 6–11)                       |    8   |   10   |   12   |
| Act II core (Slides 12–16)                |   10   |   14   |   18   |
| European reach + Chaos (Slides 17–18)     |   2    |    5   |    7   |
| Why / Objections / Next step (Slides 19–22) |    4   |    5   |    7   |
| Thank-you + Q&A buffer                    |    3   |    6   |    9   |

> **Cuts for 30 min:** drop slide 18 (Chaos Controller deep-dive); keep
> the catalogue verbal. Trim slide 17 to one minute.
> **Adds for 60 min:** dwell longer on slide 14 (Tag Spotlight) — pivot
> by 4 dimensions, not 3; expand slide 16 with the ITSI Episode click-through.

---

## Slide-by-slide

Each entry below mirrors a slide in the deck. The same text is attached
as **speaker notes** inside the `.pptx` so it travels with the file —
the headings here exist so you can scroll the markdown on a second
monitor while the deck advances on the primary.

### Slide 1 — Title: "NatWest Payment Platform"

Hold for one beat. Frame the room before clicking forward.

> "A customer just told your support desk their payment is slow. Today
> I want to show you six minutes from that phone call to the exact line
> of code that regressed — across 24 services, two programming
> languages, and nine European cities, all on one trace ID."

Move on after ~30 seconds.

### Slide 2 — Agenda

30-second sweep. Two anchors are Act I (depth, one investigation) and
Act II (breadth, six surfaces). Everything else is supporting evidence.

If the audience is VP-Payments / business: stress slides 14, 16, 17. If
SRE-heavy: stress slides 7–11 plus slide 18.

### Slide 3 — Hook statement

Pause for one beat after the heading. Read the line out loud as the
audience absorbs it.

> "Today the on-call walk takes 30–45 minutes and three to five tools.
> We are going to do it on one screen, on one trace ID, in six minutes."

Bridge straight into slide 4 without taking questions yet.

### Slide 4 — The platform under the lens

Walk the scale of the simulated bank in ~60 seconds. The five numbers
to hit verbally:

- 24 services
- 9 European cities (sets up slide 17)
- 3 customer tiers (Bronze / Silver / Gold — visible in the SPA persona
  selector)
- ~3,000 transactions per minute at peak
- One mental model across every surface

Do **not** enumerate the schemes. "Every UK payment scheme" is the
verbal beat.

### Slide 5 — Capability matrix (table)

The "what you're about to see" anchor. Do **not** read every row. Pick
two and tease the rest:

> "RUM ties the customer click to the trace. AlwaysOn Profiling lands
> on the line of code. We are going to do the whole walk on one trace
> ID — and the same matrix will return at the end as a bracket."

Move quickly. The table exists to give the audience a mental map, not
to be a script.

### Slide 6 — Segue: Act I

Two seconds.

> "One customer click. One trace ID. Six minutes. No copy-paste."

Switch the browser to Splunk Observability Cloud (Tab 1).

### Slide 7 — Act I.1: Customer click (RUM)

Live actions, in order:

1. SPA → click **Send payment** (Olivia/Bronze for the safe path,
   Sofia/Madrid if you want to seed the geographic story).
2. RUM → **Sessions** → open the session you just made (newest at the
   top).
3. Hover the page-action span; show the `traceparent` attribute.
4. Right-click → **APM trace**.

Close out:

> "Forty-seven seconds ago this customer pressed Send. They felt a
> 1.4-second wait. We never asked them anything — the SDK handed us
> the trace."

**Ask beat (hold for a count of three):** "How long does it take your
team today to go from 'a customer is complaining' to 'I have the
trace'?"

### Slide 8 — Act I.2: Slow span (APM)

Walk the trace tree slowly enough for the audience to read service
names: `web-frontend → api-gateway → payment-initiation → fraud-detection`.

Stop on `fraud-detection-service`. Surface:

- `compute_fraud_features` — the new CPU-bound child span.
- Business attributes on the span: `fraud.algo = pairwise`,
  `fraud.feature_count = 96`, `payment.scheme = SWIFT`,
  `customer.tier = bronze`.
- **Optional side-quest** (45 s): scroll to `ledger-service` JDBC
  spans, point at `db.system = postgresql`, tease DB Query Performance.

Close out:

> "Slow is fraud-detection. Hypothesis live. Now I want the log line
> this code wrote, on this pod, on this trace."

**Ask beat:** "How many tools is that journey today — two? three? five?"

### Slide 9 — Act I.3: Logs in Context

The architectural moment of the demo. Don't rush it.

On the same APM span → **Logs for this trace**. One structured JSON
record from `fraud-detection-service` returns. Read out the `trace_id`
(matches the APM span) and the customer-level fields.

The bridge — say this slowly:

> "Container logs ship via the Splunk OTel Collector to the in-VPC
> Splunk Enterprise instance over HEC 8088. Log Observer Connect
> federates them into Observability Cloud. **Your existing Splunk
> Enterprise becomes the log surface for o11y. Same governance, same
> retention, same indexers. The trace ID survives the seam.**"

If the audience is Splunk-incumbent, dwell here. This is the
no-log-re-platform argument and it matters more than the tracing
itself.

### Slide 10 — Act I.4: Line of code (AlwaysOn Profiling)

The credibility moment. Two clicks:

1. On the APM span → expand **AlwaysOn Profiling**.
2. Switch the flame graph to **Diff vs. baseline**.

The new tower at the top is `_extract_features_pairwise` inside
`compute_fraud_features`. The frame name is the line of code.

Close out:

> "Profiling diff is what makes a slow trace actionable. Not
> 'fraud-detection regressed' — but which line of which file regressed
> it. AlwaysOn Profiling samples every JVM and every Python process in
> production, all the time, at roughly 1 % CPU overhead. The cluster
> you are looking at is doing it right now, in this room."

**Ask beat:** "How often, today, does an investigation actually finish
on a line of code — not a hunch?"

### Slide 11 — Act I.5: Recover

```bash
scripts/incident.sh recover
```

(Or click **Clear** on the relevant scenario in the SPA's Chaos
Controller tab — both wire to the same controller.)

Watch the p99 panel settle within ~30 s. Refresh the SPA; the next
payment clears fast. Profiling diff: the regression tower is gone.

Bracket — **do not** skip this line:

> "RUM → APM → log → profile, in six minutes, on one page. Same data
> plane, same dimensions, same trace ID. That is what a NatWest
> engineer's Tuesday afternoon should look like."

**Pause.** This is where the first real audience question lands.
Absorb 2–3 minutes of discussion before moving on.

### Slide 12 — Segue: Act II

Two seconds.

> "You have just watched one investigation. Let me show you what else
> this surface does without changing tools."

### Slide 13 — Act II.A: Service map

Open the service map and let it render for one beat before talking.
The graph alone earns a reaction.

Three call-outs, in order:

1. The shape of the mesh is the payments topology you signed off in
   the architecture diagram. **Nothing in this map was drawn by hand.**
2. The infra nodes (Postgres, Redis, Kafka) are **inferred** from OTel
   client spans. No exporters or agents on the data plane.
3. The dotted edge between `payment-initiation` and `settlement` is
   the Kafka producer/consumer relationship — APM stitches asynchronous
   flows the same way as synchronous ones.

**Ask beat:** "When was the last time you saw your payments topology
this clearly, with the data plane in the same picture?"

### Slide 14 — Act II.B: Tag Spotlight

Live pivots, in order:

1. APM → **Tag Spotlight** on `api-gateway`, last hour.
2. Pivot by `payment.scheme` — **SWIFT** wins on p99.
3. Pivot by `customer.tier` — Bronze / Silver / Gold cohorts. Gold p95
   sits visibly below Bronze (fraud fast-path); Bronze decline rate is
   the canary the dedicated detector watches.
4. Pivot by `customer.location` — **Madrid** sits visibly above the
   other cities at baseline. This is the bridge into slide 17.
5. **Optional fourth pivot:** `payment.roaming = true` to surface the
   ~5 % cross-border tail. Useful if the audience is fraud / PSD2
   focused.

Talking point:

> "Every span carries business context. 'Which scheme is hurting which
> tier right now' is a pivot, not a JIRA ticket to the data team. And
> the same dimension is on the RUM page-load span, the API span, the
> database span, all the way through."

**Ask beat:** "If your VP of Payments asked you which scheme is hurting
which tier right now — how long would it take to answer?"

### Slide 15 — Act II.C: Detectors, SLOs, Synthetics

Pick two, not all five. Recommended pair:

- **swift-counterparty-flap** — fires within 30 s, very visual, covers
  the o11y → ITSI Episode bridge.
- **madrid-network-degradation** — sets up the European story. Pre-arm
  it if you want the detector already red when you land on slide 17.

```bash
scripts/incident.sh swift-counterparty-flap
# …or, with the SPA in front of you, click Inject on the same scenario
```

The `[NatWest demo] SWIFT error rate` detector fires Critical. Click
through → alert detail → threshold band → runbook URL. Open Synthetic
Monitoring → `[NatWest demo] payments gateway` and show the same
incident from the synthetic probe's perspective.

Close out:

> "Detectors don't replace your eyes — they buy them back. The team
> sleeps; the platform watches."

### Slide 16 — Act II.D: ITSI, Episodes, Glass tables

Open the `natwest-payments-overview` glass table. Walk it top-to-bottom:

1. The four headline business outcomes — Payments per minute, Value
   authorised, Customers impacted, Success rate.
2. The new **Payments by City** row — per-city p95 table, customer-origin
   choropleth, and the roaming-payment p95 timechart.
3. From the Madrid panel → click into **Episode Review** → show the
   open Episode (correlated from the Splunk Observability detector AND
   the `payments_madrid_latency_breach` correlation search).

Talking point:

> "Splunk Observability tells the SRE *which service*. ITSI rolls that
> up to *which business outcome* — same trace, different audience.
> Same Episode, same severity, all the way to a ServiceNow incident if
> you've wired the bridge."

### Slide 17 — European customer reach (NEW)

This is the new narrative we built on top of the original demo. Three
minutes if the room is geographic / payment-scheme focused; one minute
otherwise.

Demo flow:

1. On Tag Spotlight, keep the `customer.location` pivot from slide 14
   visible. Madrid stands proud at baseline (~450 ms RTT).
2. Mention realism beats **verbally**, don't click through unless
   asked:
   - Weekend RPS curve (`RPS_SCHEDULE_WEEKEND`).
   - 2026 bank-holiday calendar per country — Madrid's traffic
     evaporates on May 1 by design.
   - Region-aware channel mix — mobile-first in EU-SOUTH, web-first in
     EU-CENTRAL.
   - ~5 % cross-border roaming — `customer.home_country` differs from
     `customer.country`, `payment.roaming = true`.
3. If asked where these are tuned: `traffic-generator/deployment.yaml`
   for live values, `helm/natwest-payments/values.yaml` for the
   `trafficGenerator` documentation block.

Talking point:

> "Payments don't stop at the M25. The platform knows where the
> customer is, where their account lives, whether they're roaming,
> and whether their country is on a public holiday today. Every span
> carries that — it's why slide 14 worked."

### Slide 18 — Chaos Controller deep-dive (optional)

Run this **only** if Act II.C went smoothly and you have at least four
minutes. Otherwise mention the controller verbally and skip to
slide 19.

If running:

1. Open the SPA's **Ops** tab. Browse the catalogue:
   - **App errors** — `bad-deploy-fraud`, `swift-counterparty-flap`,
     `sanctions-cache-disabled`.
   - **Latency** — `db-slow`, `tail-latency-storm`,
     `gateway-timeout-squeeze`, **`madrid-network-degradation`** (NEW).
   - **Customer tier** — `inject-tier-throttle`, `gold-fast-path-off`.
   - **Infra outages** — `kill-service`, `postgres-outage`,
     `redis-outage`, `kafka-outage`.
2. Click **Inject** on `madrid-network-degradation`. The controller
   patches `LOCATION_LATENCY_PROFILES` on the traffic-generator
   deployment.
3. Switch to the ITSI Payments by City glass table (slide 16's view).
   Madrid is now red within ~60 seconds. The other eight cities stay
   flat.
4. Click **Clear**. Settle.

Two security beats worth mentioning if asked:

- The presenter token is read from a header; never stored in
  `localStorage` / `sessionStorage`.
- The controller's RBAC is role-scoped to the `natwest` namespace —
  no cluster-scoped verbs, no secrets, no exec.

### Slide 19 — Why this matters (statement)

Pause for two beats after the title.

> "The investigation you watched in the first six minutes — that is
> what good looks like, every day. Not the heroic war room. The
> Tuesday afternoon."

If you have time for one more line:

> "We didn't move your log estate. We didn't change your language
> stack. We turned on OTel, and the platform did the rest."

### Slide 20 — Objections (table)

Don't pre-emptively read the objections. Use this slide as a safety
net when one comes from the floor — there are six common ones on the
slide, and the wording on the slide is paste-ready into a follow-up
email.

If asked about **cost / per-span / per-host pricing**, refuse politely:

> "Happy to walk through that with your AE on a separate motion. The
> architecture choice doesn't change with the licensing model — what
> you saw today is the technical capability, decoupled."

### Slide 21 — Next step

The ask. Land it explicitly:

> "I want to spend sixty minutes against your real services, with your
> SRE lead and your payments-ops lead in the room. We bring the
> collector config; you bring two services. By the end of the hour,
> they are on the service map."

Wait for the next move. Do not pitch beyond this slide.

### Slide 22 — Champion brief (quote)

Read out loud only if the audience seems energised at this point.
Otherwise let it sit on screen — the wording is paste-ready into a
Slack DM or champion email. The full paste-ready brief lives in
`docs/presentation/TALK_TRACK.md` (the original deep-talk-track
companion).

### Slide 23 — Thank you

Final slide. Hand the room back to the AE.

If the demo wobbled mid-flight and you need to recover before Q&A:

```bash
scripts/incident.sh recover
kubectl -n natwest rollout status deploy/fraud-detection-service
kubectl -n natwest rollout status deploy/payment-initiation-service
kubectl -n natwest get pods | grep -v Running   # should be empty
```

---

## Recovery / failure modes

| Symptom                                                    | Fix                                                                                                                                                       |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| SPA blank                                                  | Hard-refresh; the RUM SDK survives reloads.                                                                                                              |
| Service Map missing nodes                                  | Wait 60–90 s; the cluster receiver flushes on a 30 s tick.                                                                                               |
| Load balancer pending (`SyncLoadBalancerFailed`)           | Org SCP blocks `CreateLoadBalancer`. Run `scripts/05a-frontend-portforward.sh` and demo on `localhost:8080`. RUM still ships to o11y over public ingest. |
| Splunk Enterprise unreachable                              | Operator IP changed. Add the `/32` to the SG via `aws ec2 authorize-security-group-ingress` or update `splunk_enterprise_web_allowed_cidrs` and re-apply. |
| `fraud-cpu-regression` not visible in profiler             | Wait 60–120 s; AlwaysOn samples on a slow tick. The diff view needs ~2 minutes of post-regression samples — that's why the pre-flight warmed it.         |
| `madrid-network-degradation` not visible on Tag Spotlight  | The traffic generator picks up the env var on its next loop iteration (~30 s). If after 90 s the Madrid bar still hasn't moved, `kubectl -n natwest rollout restart deploy/traffic-generator` and wait two minutes. |

---

## Companion documents

- [`TALK_TRACK.md`](./TALK_TRACK.md) — the longer, deep-narrative talk
  track with full Tell-Show-Tell beats, audience matrices, objection
  handling, competitive positioning and champion brief. Use it as the
  prep document.
- [`SLIDES.md`](./SLIDES.md) — the original Marp source for the legacy
  `slides.pptx` deck (kept for reference; this Splunk-templated deck is
  the new default).
- [`build_pptx.py`](./build_pptx.py) — the renderer that produces
  `natwest-splunk-demo.pptx` from the Splunk 2026 `.pptx` template.
  Edit the `DECK` list in that file to change slide content; re-run the
  script to rebuild.
- [`../../scripts/run-of-show.md`](../../scripts/run-of-show.md) —
  operational drive script with the full `incident.sh` catalogue and
  cluster checks.

---

## Rebuilding the deck

```bash
# One-time virtualenv
python3 -m venv /tmp/pptxenv
/tmp/pptxenv/bin/pip install python-pptx

# Render
/tmp/pptxenv/bin/python3 docs/presentation/build_pptx.py \
  --template /Users/mserieys/Library/CloudStorage/OneDrive-Cisco/_Cursor/splunk-deck-2026.pptx \
  --out docs/presentation/natwest-splunk-demo.pptx
```

Speaker notes for every slide are embedded in the `.pptx` automatically
— PowerPoint's Presenter View will display them on the second monitor.
