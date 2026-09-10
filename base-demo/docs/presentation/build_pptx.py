"""Render the NatWest payments demo deck from the Splunk 2026 template.

Usage:
    python3 -m venv /tmp/pptxenv
    /tmp/pptxenv/bin/pip install python-pptx
    /tmp/pptxenv/bin/python3 docs/presentation/build_pptx.py \
        --template /Users/mserieys/Library/CloudStorage/OneDrive-Cisco/_Cursor/splunk-deck-2026.pptx \
        --out docs/presentation/natwest-splunk-demo.pptx

The script keeps the template's master/layouts/colours intact and inserts
content slides one by one. Speaker notes attached to each slide map
straight onto the slide-aligned beats in
docs/presentation/DEMO_DECK_TALK_TRACK.md so the deck and the talk track
stay in lockstep.

Design rules:
- One layout per intent (title / segue / 1-col / 2-col / 3-col / table /
  statement / quote / thank-you).
- Title placeholders carry the heading; BODY placeholders carry bullet
  text. Multi-level bullets use a leading TAB character per level so
  python-pptx maps them onto the master's existing bullet styles.
- Tables (capability matrix, objection handling) render into a table
  placeholder via the layout=Table flow. Cells are kept short on
  purpose; the prose lives in the talk track.
- No hard-coded colours - the template is pre-themed and we want the
  deck to obey the corporate palette automatically.
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Sequence

from pptx import Presentation
from pptx.enum.text import PP_ALIGN
from pptx.util import Pt


# ---------------------------------------------------------------------------
# Layout indices we'll use. Kept here as named constants so the slide
# definitions read like prose.
# ---------------------------------------------------------------------------
L_TITLE = 0          # Title Slide 1, Two Speakers
L_AGENDA = 8         # Agenda 1
L_TITLE_ONLY = 9     # Title Only 1
L_TITLE_SUB = 10     # Title, Subtitle Only 1
L_SECTION_TITLE = 12 # Section, Title Only 1
L_SECTION_TITLE_SUB = 13 # Section, Title, Subtitle
L_ONE_COL = 19       # Title, 1 Column with Bullets
L_TWO_COL = 20       # Title, 2 Columns with Bullets
L_THREE_COL = 22     # Title, Subtitle, 3 Columns
L_QUOTE = 39         # Quote 1
L_TABLE = 45         # Title, Subtitle, Table 1
L_STATEMENT = 47     # Statement 1, Title, Subtitle
L_SEGUE = 49         # Segue 1
L_THANK_YOU = 53     # Thank you 1


# Placeholder idx within each layout. python-pptx exposes placeholders by
# idx (stable across copies) rather than by name, so we record the
# indices we observed in the template once.
PH_TITLE_SLIDE = {
    "title": 0,
    "subtitle": 13,
    "speaker1": 16,
    "speaker2": 14,
    "date": 12,
}
PH_AGENDA = {"title": 0, "number": 20, "body": 18}
PH_ONE_COL = {"title": 0, "body": 12}
PH_TWO_COL = {"title": 0, "left": 14, "right": 15}
PH_THREE_COL = {"title": 0, "subtitle": 11, "col1": 13, "col2": 14, "col3": 15}
PH_TABLE = {"title": 0, "subtitle": 11, "table": 13}
PH_STATEMENT = {"title": 0, "subtitle": 11}
PH_QUOTE = {"title": 0, "attribution": 12}
PH_SEGUE = {"title": 0}
PH_SECTION_TITLE_SUB = {"section": 12, "title": 0, "subtitle": 13}


@dataclass
class Bullet:
    """One bullet line. level=0 is top-level; level>=1 are sub-bullets."""

    text: str
    level: int = 0


@dataclass
class Slide:
    """One slide definition: layout + payload + speaker notes."""

    layout: int
    title: str = ""
    subtitle: str = ""
    bullets: list[Bullet] = field(default_factory=list)
    columns: list[list[Bullet]] = field(default_factory=list)
    table: list[list[str]] = field(default_factory=list)
    notes: str = ""
    # Per-slide overrides used only by a couple of layouts.
    section: str = ""
    speakers: list[str] = field(default_factory=list)
    date: str = ""
    agenda_number: str = ""
    quote_attribution: str = ""


# ---------------------------------------------------------------------------
# Slide definitions. The order here is the running order of the deck.
# Keep slide content terse; the prose lives in DEMO_DECK_TALK_TRACK.md.
# ---------------------------------------------------------------------------
DECK: list[Slide] = [
    # ---- 1. Cover --------------------------------------------------------
    Slide(
        layout=L_TITLE,
        title="NatWest Payment Platform",
        subtitle="Observability without seams - 24 services, 9 cities, one trace ID",
        speakers=[
            "Solution Engineering  -  Splunk Observability Cloud + ITSI",
            "Cisco  /  Splunk Demo Day  -  May 2026",
        ],
        date="May 2026",
        notes=(
            "Open with the room dark and the SPA visible behind you.\n\n"
            "Do not read the title. Hold the slide for one beat, then frame the room:\n"
            "  'A customer just told your support desk their payment is slow. "
            "  Today I want to show you six minutes from that phone call to the "
            "  exact line of code that regressed - across 24 services, two "
            "  programming languages, and nine European cities, all on one trace ID.'\n\n"
            "Move on after roughly 30 seconds."
        ),
    ),

    # ---- 2. Agenda -------------------------------------------------------
    Slide(
        layout=L_AGENDA,
        title="Agenda",
        agenda_number="01",
        bullets=[
            Bullet("Why we built this demo"),
            Bullet("Act I  -  The 6-minute investigation  (RUM \u2192 APM \u2192 LOC \u2192 Profiling)"),
            Bullet("Act II  -  Breadth tour  (service map, Tag Spotlight, detectors, ITSI)"),
            Bullet("European customer reach  -  Madrid, roaming, weekends, bank holidays"),
            Bullet("Chaos Controller  -  scripted incidents, one click recovery"),
            Bullet("Why this matters, objections, next step"),
        ],
        notes=(
            "Run through the agenda in roughly 30 seconds. The two anchors are "
            "Act I (depth, single investigation) and Act II (breadth, six "
            "surfaces). Everything else is supporting.\n\n"
            "If the audience is heavily VP-Payments / business: stress the "
            "European reach and ITSI rows. If SRE-heavy: stress Act I and the "
            "chaos controller."
        ),
    ),

    # ---- 3. Hook statement ----------------------------------------------
    Slide(
        layout=L_STATEMENT,
        title="From a customer click to a line of code, in six minutes.",
        subtitle=(
            "One trace ID survives every product surface  -  RUM, APM, logs, "
            "profiler, infra. No copy-paste between tools."
        ),
        notes=(
            "The hook slide. Pause for one beat after the heading.\n\n"
            "'Today the on-call walk takes 30-45 minutes and three to five "
            "tools. We are going to do it on one screen, on one trace ID, in "
            "six minutes.' Bridge directly into the next slide."
        ),
    ),

    # ---- 4. The platform under the lens ---------------------------------
    Slide(
        layout=L_ONE_COL,
        title="The platform under the lens",
        bullets=[
            Bullet("24 microservices  -  Python + Java, polyglot OTel auto-instrumentation"),
            Bullet("6 UK / European payment schemes  -  FPS, BACS, CHAPS, SEPA, SWIFT, Cheque"),
            Bullet("3 customer tiers  -  Bronze (60 %), Silver (30 %), Gold (10 %)"),
            Bullet("9 European cities driving traffic  -  London, Frankfurt, Paris, Madrid, Milan, Amsterdam, Dublin, Lisbon, Brussels"),
            Bullet("~ 3,000 transactions / minute at peak  -  realistic UK retail-bank curve, weekday + weekend"),
            Bullet("Infra  -  EKS, RDS Postgres, ElastiCache Redis, MSK Kafka, AWS observability + ThousandEyes"),
            Bullet("Splunk surfaces  -  Observability Cloud (RUM/APM/Profiling/Synthetics) + Splunk Enterprise + ITSI"),
        ],
        notes=(
            "Walk the audience through the scale of the simulated bank in "
            "about 60 seconds. The five numbers to hit out loud are:\n"
            "  - 24 services\n"
            "  - 9 European cities (so the Madrid story has context)\n"
            "  - 3 tiers (Bronze / Silver / Gold personas in the SPA)\n"
            "  - ~3,000 TPM peak\n"
            "  - One mental model across every surface\n\n"
            "Do NOT enumerate the schemes; the bullet is for the slide, the "
            "verbal beat is 'every UK payment scheme'."
        ),
    ),

    # ---- 5. Capability matrix (table) -----------------------------------
    Slide(
        layout=L_TABLE,
        title="What you're about to see",
        subtitle="Six product surfaces, one investigation",
        table=[
            ["Surface", "Question it answers"],
            ["RUM",                          "Which customer felt this, and when?"],
            ["APM",                          "Which service inside the bank slowed them down?"],
            ["AlwaysOn Profiling",           "Which line of code is burning the CPU?"],
            ["Logs in Context (LOC)",        "Show me this customer's log line, on this trace."],
            ["DB Query Performance",         "Which SQL template is dragging settlement?"],
            ["Detectors / SLOs / Synthetics", "Tell me before the customer does."],
        ],
        notes=(
            "Capability matrix - resist the temptation to read every row.\n\n"
            "Pick two and tease the rest:\n"
            "  'RUM ties the customer click to the trace. AlwaysOn Profiling "
            "  lands on the line of code. We are going to do the whole walk "
            "  on one trace ID - and the same matrix will return at the end "
            "  as a bracket.'\n\n"
            "Move quickly - the table is here to anchor the audience, not to "
            "be read aloud."
        ),
    ),

    # ---- 6. Segue: Act I -------------------------------------------------
    Slide(
        layout=L_SEGUE,
        title="Act I  -  The 6-minute investigation",
        notes=(
            "Segue slide. Two seconds.\n\n"
            "'One customer click. One trace ID. Six minutes. No copy-paste.'\n\n"
            "Switch the browser to Splunk Observability Cloud, scoped to "
            "environment=demo, with the SPA visible in tab 2."
        ),
    ),

    # ---- 7. Act I.1 RUM -------------------------------------------------
    Slide(
        layout=L_ONE_COL,
        title="Act I  -  1   Customer click  (Splunk RUM)",
        bullets=[
            Bullet("Submit one SWIFT payment from the SPA  -  Olivia (Bronze) or Sofia (Madrid)"),
            Bullet("RUM \u2192 Sessions: the page-action span Send payment is already there"),
            Bullet("W3C traceparent header links the click to a server-side trace - automatically"),
            Bullet("Span attributes already carry customer.tier, customer.location, customer.country"),
            Bullet("One click on APM trace - we are now inside the bank"),
            Bullet("Ask: how long does it take your team today to go from 'a customer is complaining' to 'I have the trace'?"),
        ],
        notes=(
            "Show, don't tell. Run the SPA action live before clicking off "
            "this slide.\n\n"
            "Beat:\n"
            "  - Click Send payment in the SPA.\n"
            "  - Switch to RUM \u2192 Sessions.\n"
            "  - Open the session you just made (newest at the top).\n"
            "  - Hover the page-action span; show the traceparent attribute.\n"
            "  - Click 'APM trace' from the RUM span context menu.\n\n"
            "Close out:\n"
            "  'Forty-seven seconds ago this customer pressed Send. They felt "
            "  a 1.4-second wait. We never asked them anything - the SDK "
            "  handed us the trace.'\n\n"
            "Hold the Ask Beat for a count of three."
        ),
    ),

    # ---- 8. Act I.2 APM -------------------------------------------------
    Slide(
        layout=L_ONE_COL,
        title="Act I  -  2   Slow span  (Splunk APM)",
        bullets=[
            Bullet("Trace tree: web-frontend \u2192 api-gateway \u2192 payment-initiation \u2192 fraud-detection"),
            Bullet("compute_fraud_features  -  new CPU-bound child span dominates the trace"),
            Bullet("Business attributes are first-class data, not afterthoughts", level=1),
            Bullet("fraud.algo = pairwise   |   fraud.feature_count = 96", level=2),
            Bullet("payment.scheme = SWIFT  |   customer.tier = bronze", level=2),
            Bullet("Side-quest: ledger-service JDBC spans - db.system=postgresql, db.statement=SELECT SUM(...)"),
            Bullet("Ask: how many tools is that journey today - two? three? five?"),
        ],
        notes=(
            "Run the click-through live.\n\n"
            "Beat:\n"
            "  - Walk down the trace tree slowly enough for the audience to "
            "    read the service names.\n"
            "  - Stop on fraud-detection-service. Surface the compute_fraud_features "
            "    span and its attributes.\n"
            "  - The point: fraud.algo / fraud.feature_count are business "
            "    dimensions a payments engineer would have queried in a "
            "    separate APM tool. Here they live next to the latency.\n"
            "  - Optional side-quest into ledger-service so DB Query Performance "
            "    is teased early.\n\n"
            "Close out:\n"
            "  'Slow is fraud-detection. Hypothesis live. Now I want the log "
            "  line this code wrote, on this pod, on this trace.'"
        ),
    ),

    # ---- 9. Act I.3 LOC -------------------------------------------------
    Slide(
        layout=L_ONE_COL,
        title="Act I  -  3   Logs in Context  (LOC)",
        bullets=[
            Bullet("Same APM span \u2192 Logs for this trace"),
            Bullet("One structured JSON record from fraud-detection-service - this trace, this pod"),
            Bullet("Fields  -  service, level, trace_id, span_id, payment_id, payment.scheme"),
            Bullet("Logs ship via Splunk OTel Collector to in-VPC Splunk Enterprise (HEC 8088)"),
            Bullet("Log Observer Connect federates them into Observability Cloud - same governance, same indexers, no log re-platform"),
            Bullet("Ask: where does this pivot live in your stack today, and how many context switches does it cost?"),
        ],
        notes=(
            "This is the architectural moment of the demo.\n\n"
            "Beat:\n"
            "  - On the same APM span, click 'Logs for this trace'.\n"
            "  - One JSON record returns. Read out the trace_id (matches the "
            "    APM span) and the customer-level fields.\n\n"
            "Key talking point - the bridge:\n"
            "  'Your existing Splunk Enterprise becomes the log surface for "
            "  Observability Cloud. Same governance, same retention, same "
            "  indexers. The trace ID survives the seam.'\n\n"
            "If the audience is Splunk-incumbent, dwell here. This is the "
            "no-log-re-platform message and it matters."
        ),
    ),

    # ---- 10. Act I.4 Profiling ------------------------------------------
    Slide(
        layout=L_ONE_COL,
        title="Act I  -  4   Line of code  (AlwaysOn Profiling)",
        bullets=[
            Bullet("Same APM span \u2192 expand AlwaysOn Profiling"),
            Bullet("CPU flame graph: _extract_features_pairwise inside compute_fraud_features dominates"),
            Bullet("Profiling diff - last 5 min vs baseline. The regression tower is unmistakable"),
            Bullet("The frame name is the line of code  -  not 'fraud-detection regressed', but which line of which file"),
            Bullet("~ 1 % CPU overhead in production. Always-on, every JVM and every Python process"),
            Bullet("Ask: how often does an investigation actually finish on a line of code today?"),
        ],
        notes=(
            "AlwaysOn Profiling is the credibility moment.\n\n"
            "Beat:\n"
            "  - Open the CPU flame graph on the fraud-detection service.\n"
            "  - Switch to 'Diff vs. baseline'.\n"
            "  - The new tower at the top is _extract_features_pairwise.\n\n"
            "Talking point that lands:\n"
            "  'Profiling diff is what makes a slow trace actionable. Not "
            "  fraud-detection regressed - but which line of which file '\n"
            "  'regressed it.'\n\n"
            "If asked about overhead: the cluster you are looking at runs "
            "profiling on every JVM and Python process at ~1% CPU, right now, "
            "in this room."
        ),
    ),

    # ---- 11. Act I.5 Recover --------------------------------------------
    Slide(
        layout=L_ONE_COL,
        title="Act I  -  5   Recover",
        bullets=[
            Bullet("Terminal: scripts/incident.sh recover  (or click Clear in the Chaos Controller)"),
            Bullet("p99 latency settles in the dashboard pane within ~30 seconds"),
            Bullet("Profiling diff: the regression tower disappears"),
            Bullet("Refresh the SPA - next payment clears fast"),
            Bullet("Bracket: RUM \u2192 APM \u2192 LOC \u2192 Profile, in six minutes, on one page"),
            Bullet("One mental model. One place every signal converges into a story."),
        ],
        notes=(
            "Close Act I deliberately.\n\n"
            "Beat:\n"
            "  - Run the recover command (or click Clear in the SPA Ops tab).\n"
            "  - Watch the p99 panel in the corner of the screen settle.\n"
            "  - Refresh the SPA and submit one more payment; it returns fast.\n\n"
            "Bracket - DON'T skip this:\n"
            "  'RUM, APM, log, profile - in six minutes, on one page. Same "
            "  data plane, same dimensions, same trace ID. That is what a "
            "  NatWest engineer's Tuesday afternoon should look like.'\n\n"
            "PAUSE. The first real question from the audience usually lands "
            "here. Absorb 2-3 minutes of discussion before moving on."
        ),
    ),

    # ---- 12. Segue: Act II ----------------------------------------------
    Slide(
        layout=L_SEGUE,
        title="Act II  -  The breadth tour",
        notes=(
            "Segue slide. Two seconds.\n\n"
            "'You have just watched one investigation. Let me show you what "
            "else this surface does without changing tools.'"
        ),
    ),

    # ---- 13. Service Map ------------------------------------------------
    Slide(
        layout=L_ONE_COL,
        title="Act II  -  A   Service map  (breadth)",
        bullets=[
            Bullet("APM \u2192 Service Map, scoped to environment = demo"),
            Bullet("24 services auto-discovered. No PRs, no per-service config"),
            Bullet("Postgres, Redis, Kafka inferred from OTel client spans - no exporter"),
            Bullet("Dotted Kafka edge: payment-initiation \u2192 settlement is async producer / consumer"),
            Bullet("Polyglot mesh: Java ledger-service middle-of-fleet, Python everywhere else"),
            Bullet("Click the Postgres node \u2192 DB Query Performance, same surface, no new tool"),
        ],
        notes=(
            "Open the service map and let it render for one beat before "
            "talking. The graph alone earns a reaction.\n\n"
            "Three things to call out, in order:\n"
            "  1. The shape of the mesh is the payments topology you signed "
            "     off in the architecture diagram. Nothing in this map was "
            "     drawn by hand.\n"
            "  2. The infra nodes (Postgres, Redis, Kafka) are INFERRED from "
            "     OTel client spans. No agents on the data plane.\n"
            "  3. The dotted edge between payment-initiation and settlement "
            "     is the Kafka producer/consumer relationship. APM stitches "
            "     asynchronous flows the same way as synchronous ones.\n\n"
            "Ask Beat: 'When was the last time you saw your payments topology "
            "this clearly, with the data plane in the same picture?'"
        ),
    ),

    # ---- 14. Tag Spotlight ----------------------------------------------
    Slide(
        layout=L_THREE_COL,
        title="Act II  -  B   Tag Spotlight  (business questions)",
        subtitle="Same span attributes pivot every panel - no JIRA ticket to the data team",
        columns=[
            [
                Bullet("By payment.scheme"),
                Bullet("SWIFT highest p99 + error rate", level=1),
                Bullet("CHAPS high value, low volume", level=1),
                Bullet("FPS dominates volume", level=1),
            ],
            [
                Bullet("By customer.tier"),
                Bullet("Bronze / Silver / Gold cohorts", level=1),
                Bullet("Gold p95 below Bronze (fast-path)", level=1),
                Bullet("Bronze decline rate is the canary", level=1),
            ],
            [
                Bullet("By customer.location"),
                Bullet("9 European cities tagged on every span", level=1),
                Bullet("Madrid 450 ms baseline RTT stands out", level=1),
                Bullet("payment.roaming flag for fraud pivots", level=1),
            ],
        ],
        notes=(
            "This is where the deck's NEW European story starts feeding the "
            "Act II flow.\n\n"
            "Demo flow:\n"
            "  1. APM \u2192 Tag Spotlight on api-gateway, last hour.\n"
            "  2. Pivot by payment.scheme - SWIFT wins on p99.\n"
            "  3. Pivot by customer.tier - Bronze / Silver / Gold cohorts.\n"
            "  4. Pivot by customer.location - Madrid sits visibly above the "
            "     other cities even at baseline.\n"
            "  5. Optional: pivot by payment.roaming = true to surface the "
            "     ~5% cross-border tail. Useful if the audience is fraud / "
            "     PSD2 focused.\n\n"
            "Talking point:\n"
            "  'Every span carries business context. \"Which scheme is hurting "
            "  which tier right now\" is a pivot, not a JIRA ticket to the "
            "  data team. And the same dimension is on the RUM page-load "
            "  span, the API span, the database span, all the way through.'"
        ),
    ),

    # ---- 15. Detectors + SLOs + Synthetics ------------------------------
    Slide(
        layout=L_ONE_COL,
        title="Act II  -  C   Detectors, SLOs, Synthetics",
        bullets=[
            Bullet("Run scripts/incident.sh swift-counterparty-flap   -or-   click Inject in the Chaos Controller"),
            Bullet("[NatWest demo] SWIFT error rate detector fires Critical within ~ 30 seconds"),
            Bullet("[NatWest demo] Madrid p95 latency  -  customer.location-scoped detector mirrors the ITSI correlation search"),
            Bullet("[NatWest demo] Bronze tier decline rate  -  catches scripts/incident.sh inject-tier-throttle bronze"),
            Bullet("Synthetic Monitoring  -  end-to-end gateway probe + ThousandEyes geographic reachability"),
            Bullet("'Detectors don't replace your eyes  -  they buy them back. The team sleeps; the platform watches.'"),
        ],
        notes=(
            "This is the alarms beat. Don't try to demo every detector - pick "
            "two.\n\n"
            "Recommended pair:\n"
            "  - swift-counterparty-flap (fast and visual; fires within "
            "    30 seconds; covers the SWIFT error-rate detector + the "
            "    o11y-to-ITSI alert bridge).\n"
            "  - madrid-network-degradation (sets up the European reach "
            "    section that follows). Pre-arm it if you want the audience "
            "    to see the detector already red.\n\n"
            "Closing line:\n"
            "  'Detectors don't replace your eyes - they buy them back. The "
            "  team sleeps; the platform watches.'"
        ),
    ),

    # ---- 16. ITSI -------------------------------------------------------
    Slide(
        layout=L_ONE_COL,
        title="Act II  -  D   ITSI: Episodes, KPIs, glass tables",
        bullets=[
            Bullet("Episode Review correlates Splunk Observability + Splunk Enterprise audit + OTel-trace correlation searches"),
            Bullet("L1 service: NatWest Card Payments  -  payments per minute, value authorised, customers impacted, success rate"),
            Bullet("L2 services include Bronze / Silver / Gold experience AND a new Payments by Location service"),
            Bullet("Payments by Location KPIs - London / Madrid / Frankfurt / Paris / Milan p95 + roaming p95 + roaming error rate"),
            Bullet("Glass table: per-city p95 table, customer-origin choropleth, roaming-payment p95 by country"),
            Bullet("Correlation searches: excessive declines by tier, chaos outside change window, Madrid p95 breach"),
        ],
        notes=(
            "ITSI is where the L1 / L2 audience (CIO, VP Payments) sees the "
            "data plane expressed as a service tree.\n\n"
            "Demo flow:\n"
            "  - Open the natwest-payments-overview glass table.\n"
            "  - Walk top-to-bottom: the four headline business outcomes at "
            "    the top, the per-city Payments by City row in the middle, "
            "    the chaos / notable-events strip below.\n"
            "  - From the Madrid panel, click into Episode Review and show "
            "    the open Episode (correlated from the o11y detector + the "
            "    payments_madrid_latency_breach correlation search).\n\n"
            "Talking point:\n"
            "  'Splunk Observability tells the SRE *which service*. ITSI "
            "  rolls that up to *which business outcome* - same trace, "
            "  different audience.'"
        ),
    ),

    # ---- 17. European customer reach (NEW) ------------------------------
    Slide(
        layout=L_THREE_COL,
        title="European customer reach",
        subtitle="The bank does not stop at the M25  -  every span carries location and home country",
        columns=[
            [
                Bullet("9 cities, weighted pool"),
                Bullet("London 40 %  -  the UK retail base", level=1),
                Bullet("Frankfurt, Paris, Amsterdam, Brussels", level=1),
                Bullet("Madrid 10 % at 450 ms RTT baseline", level=1),
                Bullet("Milan, Dublin, Lisbon round out the long tail", level=1),
            ],
            [
                Bullet("Realism dial"),
                Bullet("Weekday + weekend RPS curves (Europe / London tz)", level=1),
                Bullet("2026 bank-holiday calendar per country", level=1),
                Bullet("Region-aware channel mix - mobile-first South, web-first DACH", level=1),
                Bullet("~ 5 % roaming  -  customer.home_country differs from customer.country", level=1),
            ],
            [
                Bullet("What it lights up"),
                Bullet("APM Tag Spotlight by customer.location", level=1),
                Bullet("Madrid p95 detector + ITSI correlation search", level=1),
                Bullet("ITSI Payments by Location service", level=1),
                Bullet("Glass-table choropleth and roaming-payment timechart", level=1),
            ],
        ],
        notes=(
            "This is the NEW European narrative. Three minutes if the audience "
            "is geographic / payment-scheme heavy; one minute otherwise.\n\n"
            "Beat:\n"
            "  1. Open the Tag Spotlight pivot on customer.location. Madrid "
            "     stands proud above the rest at baseline.\n"
            "  2. Mention realism beats - weekend curve, bank holidays - "
            "     verbally, do not click through unless asked.\n"
            "  3. Hover the payment.roaming attribute in a trace and explain "
            "     the ~5% cross-border baseline. Tease the fraud-incident "
            "     story (ROAMING_RATE chaos lever).\n\n"
            "Optional aside if asked:\n"
            "  - The exact city pool, weekend curve, bank-holiday list and "
            "    roaming rate are tuned in traffic-generator/deployment.yaml "
            "    and mirrored under trafficGenerator in helm values."
        ),
    ),

    # ---- 18. Chaos Controller -------------------------------------------
    Slide(
        layout=L_TWO_COL,
        title="Chaos Controller  -  scripted incidents, one click recovery",
        columns=[
            [
                Bullet("Catalogue (live, in the SPA)"),
                Bullet("App errors", level=1),
                Bullet("bad-deploy-fraud, swift-counterparty-flap, sanctions-cache-disabled", level=2),
                Bullet("Latency", level=1),
                Bullet("db-slow, tail-latency-storm, gateway-timeout-squeeze", level=2),
                Bullet("madrid-network-degradation  -  NEW", level=2),
                Bullet("Customer tier", level=1),
                Bullet("inject-tier-throttle, gold-fast-path-off", level=2),
                Bullet("Infra outages", level=1),
                Bullet("kill-service, postgres-outage, redis-outage, kafka-outage", level=2),
            ],
            [
                Bullet("madrid-network-degradation walkthrough"),
                Bullet("One-click Inject from the SPA / Ops tab", level=1),
                Bullet("Patches traffic-generator env var LOCATION_LATENCY_PROFILES", level=1),
                Bullet("Madrid p95 jumps ~ 450 ms \u2192 ~ 2,000 ms within ~ 1 minute", level=1),
                Bullet("Madrid p95 detector fires Critical, ITSI Episode opens", level=1),
                Bullet("Other 8 cities stay flat - the story is geographic, not global", level=1),
                Bullet("One-click Clear restores the baseline", level=1),
                Bullet("Namespace-scoped RBAC - patch our own deployments, nothing else", level=1),
            ],
        ],
        notes=(
            "Optional Act II beat - run it only if Act II.C went well and "
            "you have time. Otherwise mention the controller verbally and "
            "move on.\n\n"
            "If running:\n"
            "  - Open the SPA Ops tab (web-frontend / ops).\n"
            "  - Browse the catalogue. Point out the four categories.\n"
            "  - Inject madrid-network-degradation. Switch back to the "
            "    Tag Spotlight pivot or the ITSI Payments by City glass "
            "    table; Madrid is now red.\n"
            "  - Clear. Settle.\n\n"
            "Two security beats worth mentioning if asked:\n"
            "  - Presenter token, never in localStorage / sessionStorage.\n"
            "  - Role-scoped to the natwest namespace; no cluster-scoped "
            "    verbs, no secrets, no exec."
        ),
    ),

    # ---- 19. Why this matters (statement) -------------------------------
    Slide(
        layout=L_STATEMENT,
        title="One mental model. One place every signal becomes a story.",
        subtitle=(
            "Mean time to context is the only metric your CEO cares about. "
            "Six product surfaces, one trace ID, no copy-paste."
        ),
        notes=(
            "The closing argument. Pause for two beats.\n\n"
            "'The investigation you watched in the first six minutes - that "
            "is what good looks like, every day. Not the heroic war room. "
            "The Tuesday afternoon.'\n\n"
            "If you have time for one more line:\n"
            "  'We did not move your log estate. We did not change your "
            "  language stack. We turned on OTel, and the platform did the "
            "  rest.'"
        ),
    ),

    # ---- 20. Objections (table) -----------------------------------------
    Slide(
        layout=L_TABLE,
        title="Objections you'll hear  -  and the demo answer",
        subtitle="Anchored in what we just walked through",
        table=[
            ["Objection", "Answer anchored in the demo"],
            ["We already have ELK / Datadog / Dynatrace.",
             "Show me where one trace ID survives RUM \u2192 APM \u2192 log \u2192 profile in your stack."],
            ["AlwaysOn Profiling will eat my CPU budget.",
             "It is running on every JVM and Python process in this demo at ~ 1 % overhead, right now."],
            ["Rolling OTel across 24 services is a multi-quarter program.",
             "We deployed those 24 services and walked away  -  Splunk distro auto-instrumented them."],
            ["We can't expose PII as span attributes.",
             "Tags are dimensions you opt in to. No PAN, no name, no PII in any span you saw."],
            ["Our log estate is on Splunk Enterprise; we can't move it.",
             "You don't. Log Observer Connect federates your existing indexers into Observability Cloud."],
            ["How is this different from APM tools that already do tracing?",
             "Profiling diff on a line of code; business attributes as pivots; auto-inferred Postgres / Redis / Kafka."],
        ],
        notes=(
            "Don't pre-emptively read the objections. Use this slide as a "
            "safety net when one comes from the floor.\n\n"
            "If asked about cost / per-span / per-host pricing: refuse "
            "politely. 'Happy to walk through that with your AE on a "
            "separate motion. The architecture choice doesn't change with "
            "the licensing model - what you saw today is the technical "
            "capability, decoupled.'"
        ),
    ),

    # ---- 21. Next step --------------------------------------------------
    Slide(
        layout=L_ONE_COL,
        title="Next step  -  60 minutes against your real services",
        bullets=[
            Bullet("We bring the Splunk OTel collector config"),
            Bullet("You bring two services - any language stack, any cloud"),
            Bullet("By the end of the hour they are on the service map  -  in your tenant, with your trace IDs"),
            Bullet("We share the Helm chart, the chaos controller, and the ITSI service-tree.yaml"),
            Bullet("Your SRE and payments-ops leads are in the room"),
            Bullet("If that lands, we scope the wider 24-service motion."),
        ],
        notes=(
            "The ask. Land it explicitly.\n\n"
            "'I want to spend sixty minutes against your real services, with "
            "your SRE lead and your payments-ops lead in the room. We bring "
            "the collector config; you bring two services. By the end of the "
            "hour, they are on the service map.'\n\n"
            "Wait for the next move. Do not pitch beyond this slide."
        ),
    ),

    # ---- 22. Quote / champion brief -------------------------------------
    Slide(
        layout=L_QUOTE,
        title=(
            "\"In six minutes Splunk Observability took a customer's slow "
            "click in RUM, followed the trace through 24 services, opened "
            "the structured log line in our existing Splunk Enterprise via "
            "LOC, and landed on the regressed line of code in AlwaysOn "
            "Profiling - with ~ 1 % CPU overhead in production.\""
        ),
        quote_attribution="NatWest payments demo  -  champion brief, paste-ready",
        notes=(
            "Hand-off slide. Use it as the 'paste this in your champion "
            "email' moment. If asked, the full brief is in "
            "docs/presentation/TALK_TRACK.md (Champion brief section)."
        ),
    ),

    # ---- 23. Thank you --------------------------------------------------
    Slide(
        layout=L_THANK_YOU,
        title="Thank you",
        notes=(
            "Final slide. Recovery script, repo, contact details all live in "
            "docs/presentation/TALK_TRACK.md (Access details section).\n\n"
            "If the demo wobbled mid-flight:\n"
            "  scripts/incident.sh recover\n"
            "  kubectl -n natwest rollout status deploy/fraud-detection-service\n"
            "  kubectl -n natwest get pods | grep -v Running   # should be empty"
        ),
    ),
]


# ---------------------------------------------------------------------------
# Renderers. Each layout has a small helper that maps the Slide payload
# onto the template's placeholders.
# ---------------------------------------------------------------------------
def _set_text(placeholder, value: str) -> None:
    """Set placeholder text without disturbing the master's style.

    python-pptx replaces the existing TextFrame contents when we assign
    .text; that wipes the bullet hierarchy stamped by the layout master.
    For multi-paragraph or bulleted content we use _set_bullets() below.
    """
    if placeholder is None:
        return
    tf = placeholder.text_frame
    tf.text = value or ""


def _set_bullets(placeholder, bullets: Sequence[Bullet]) -> None:
    """Populate a body placeholder with leveled bullets.

    The first bullet replaces the placeholder's first (empty) paragraph;
    subsequent bullets are appended. Each bullet inherits the layout
    master's bullet style for its level.
    """
    if placeholder is None or not bullets:
        return
    tf = placeholder.text_frame
    tf.clear()
    first = True
    for b in bullets:
        if first:
            p = tf.paragraphs[0]
            first = False
        else:
            p = tf.add_paragraph()
        p.text = b.text
        p.level = max(0, min(8, b.level))


def _find_placeholder(slide, idx: int):
    """Return the placeholder with the given idx, or None."""
    for ph in slide.placeholders:
        if ph.placeholder_format.idx == idx:
            return ph
    return None


def _set_notes(slide, notes: str) -> None:
    if not notes:
        return
    ns = slide.notes_slide
    tf = ns.notes_text_frame
    tf.text = notes


def _render_title(slide, payload: Slide) -> None:
    _set_text(_find_placeholder(slide, PH_TITLE_SLIDE["title"]), payload.title)
    _set_text(_find_placeholder(slide, PH_TITLE_SLIDE["subtitle"]), payload.subtitle)
    if payload.speakers:
        _set_text(_find_placeholder(slide, PH_TITLE_SLIDE["speaker1"]), payload.speakers[0])
        if len(payload.speakers) > 1:
            _set_text(_find_placeholder(slide, PH_TITLE_SLIDE["speaker2"]), payload.speakers[1])
    _set_text(_find_placeholder(slide, PH_TITLE_SLIDE["date"]), payload.date)


def _render_agenda(slide, payload: Slide) -> None:
    _set_text(_find_placeholder(slide, PH_AGENDA["title"]), payload.title)
    _set_text(_find_placeholder(slide, PH_AGENDA["number"]), payload.agenda_number)
    _set_bullets(_find_placeholder(slide, PH_AGENDA["body"]), payload.bullets)


def _render_one_col(slide, payload: Slide) -> None:
    _set_text(_find_placeholder(slide, PH_ONE_COL["title"]), payload.title)
    _set_bullets(_find_placeholder(slide, PH_ONE_COL["body"]), payload.bullets)


def _render_two_col(slide, payload: Slide) -> None:
    _set_text(_find_placeholder(slide, PH_TWO_COL["title"]), payload.title)
    if payload.columns:
        _set_bullets(_find_placeholder(slide, PH_TWO_COL["left"]), payload.columns[0])
    if len(payload.columns) > 1:
        _set_bullets(_find_placeholder(slide, PH_TWO_COL["right"]), payload.columns[1])


def _render_three_col(slide, payload: Slide) -> None:
    _set_text(_find_placeholder(slide, PH_THREE_COL["title"]), payload.title)
    _set_text(_find_placeholder(slide, PH_THREE_COL["subtitle"]), payload.subtitle)
    cols = payload.columns or []
    for key, col in zip(("col1", "col2", "col3"), cols):
        _set_bullets(_find_placeholder(slide, PH_THREE_COL[key]), col)


def _render_segue(slide, payload: Slide) -> None:
    _set_text(_find_placeholder(slide, PH_SEGUE["title"]), payload.title)


def _render_statement(slide, payload: Slide) -> None:
    _set_text(_find_placeholder(slide, PH_STATEMENT["title"]), payload.title)
    _set_text(_find_placeholder(slide, PH_STATEMENT["subtitle"]), payload.subtitle)


def _render_quote(slide, payload: Slide) -> None:
    _set_text(_find_placeholder(slide, PH_QUOTE["title"]), payload.title)
    _set_text(_find_placeholder(slide, PH_QUOTE["attribution"]), payload.quote_attribution)


def _render_table(slide, payload: Slide) -> None:
    _set_text(_find_placeholder(slide, PH_TABLE["title"]), payload.title)
    _set_text(_find_placeholder(slide, PH_TABLE["subtitle"]), payload.subtitle)
    if not payload.table:
        return
    rows = len(payload.table)
    cols = max(len(r) for r in payload.table)
    ph = _find_placeholder(slide, PH_TABLE["table"])
    if ph is None:
        return
    # Insert a real table into the table placeholder's box, then remove
    # the placeholder so the slide doesn't show 'Click to add table'.
    left, top, width, height = ph.left, ph.top, ph.width, ph.height
    sp = ph._element
    sp.getparent().remove(sp)
    table_shape = slide.shapes.add_table(rows, cols, left, top, width, height)
    table = table_shape.table
    # First row = header. Body rows below.
    for r, row in enumerate(payload.table):
        for c, val in enumerate(row):
            cell = table.cell(r, c)
            cell.text = val
            for paragraph in cell.text_frame.paragraphs:
                for run in paragraph.runs:
                    run.font.size = Pt(14 if r == 0 else 12)
                    if r == 0:
                        run.font.bold = True


def _render_thank_you(slide, payload: Slide) -> None:
    _set_text(_find_placeholder(slide, 0), payload.title or "Thank you")


# ---------------------------------------------------------------------------
# Top-level build.
# ---------------------------------------------------------------------------
RENDERERS = {
    L_TITLE:        _render_title,
    L_AGENDA:       _render_agenda,
    L_ONE_COL:      _render_one_col,
    L_TWO_COL:      _render_two_col,
    L_THREE_COL:    _render_three_col,
    L_SEGUE:        _render_segue,
    L_STATEMENT:    _render_statement,
    L_QUOTE:        _render_quote,
    L_TABLE:        _render_table,
    L_THANK_YOU:    _render_thank_you,
}


def _drop_template_slides(prs) -> None:
    """Remove the template's sample slides from the presentation.

    Removes entries from ``slides._sldIdLst`` AND drops the matching
    relationships from the presentation part so the orphan slide parts
    are no longer reachable from the package root.
    """
    pres_part = prs.part
    sldIdLst = prs.slides._sldIdLst
    rIds_to_drop: list[str] = []
    for sldId in list(sldIdLst):
        rIds_to_drop.append(sldId.rId)
        sldIdLst.remove(sldId)
    for rId in rIds_to_drop:
        pres_part.drop_rel(rId)


def build(template_path: Path, out_path: Path) -> int:
    # Two-pass build: first save a "clean template" copy with the example
    # slides removed, then re-open that and add our content. The pass-1
    # save flushes the orphan slide parts out of the package so pass-2
    # can allocate fresh partnames without colliding (the
    # zipfile.UserWarning that python-pptx emits otherwise is harmless
    # but confuses PowerPoint when the same partname appears twice in
    # the saved archive).
    import tempfile

    with tempfile.TemporaryDirectory() as td:
        cleaned = Path(td) / "cleaned_template.pptx"
        first = Presentation(str(template_path))
        _drop_template_slides(first)
        first.save(str(cleaned))
        prs = Presentation(str(cleaned))

    for i, payload in enumerate(DECK):
        layout = prs.slide_layouts[payload.layout]
        slide = prs.slides.add_slide(layout)
        renderer = RENDERERS.get(payload.layout)
        if renderer is None:
            print(f"[warn] slide {i + 1}: no renderer for layout {payload.layout}",
                  file=sys.stderr)
        else:
            renderer(slide, payload)
        _set_notes(slide, payload.notes)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    prs.save(str(out_path))
    print(f"[ok] wrote {out_path}  ({len(DECK)} slides)")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--template",
        type=Path,
        required=True,
        help="Path to the Splunk 2026 .pptx template.",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("docs/presentation/natwest-splunk-demo.pptx"),
        help="Where to write the rendered deck.",
    )
    args = parser.parse_args(argv)
    if not args.template.exists():
        print(f"[err] template not found: {args.template}", file=sys.stderr)
        return 2
    return build(args.template, args.out)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
