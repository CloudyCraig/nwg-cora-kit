#!/usr/bin/env python3
"""Generate the NatWest payments demo deck using the Splunk PowerPoint template.

Two profiles are bundled:

  * ``engineer``     - bottom-up Acts I + II cut (~20 min), aligned with
                       ``docs/presentation/TALK_TRACK.md``. **Default.**
  * ``exec-topdown`` - top-down C-level cut (~30 min), aligned with
                       ``docs/presentation/EXEC_DEMO_30MIN_TOPDOWN.md``.
                       Glass Table -> ITSI episode -> APM root cause ->
                       live Madrid inject -> RUM -> ITSI breadth +
                       ThousandEyes -> SLO burn -> close.

Each profile's deck content is defined declaratively as a list of
:class:`Slide` records (``ENGINEER_SLIDES`` / ``EXEC_TOPDOWN_SLIDES``).
Each slide names a layout from the Splunk template (we surveyed all 56 in
:func:`_log_layouts`), plus the values for each placeholder index we want
populated. Speaker notes live alongside the slide body and travel into the
.pptx as PowerPoint presenter notes.

Run:

  # default (engineer / bottom-up) cut
  python3 scripts/generate-deck.py \
    --template /path/to/splunk-deck-2026.pptx \
    --output   docs/presentation/slides.pptx

  # exec / top-down cut
  python3 scripts/generate-deck.py \
    --profile  exec-topdown \
    --template /path/to/splunk-deck-2026.pptx
    # -> docs/presentation/slides-exec-topdown.pptx by default

Re-run any time the talk track changes; both output files are
gitignored.

Why this exists rather than `marp -o slides.pptx`:
  Marp emits an isolated theme it builds itself. There's no hook for
  consuming an external PPTX as a template, so the Splunk visual identity
  (master slide, fonts, footer, segue layouts) is unreachable from Marp.
  python-pptx, in contrast, opens the template *as the deck*, and any new
  slide we add inherits its master/theme automatically.
"""

from __future__ import annotations

import argparse
import logging
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

try:
    from pptx import Presentation
    from pptx.enum.shapes import PP_PLACEHOLDER
except ImportError as e:  # pragma: no cover
    sys.stderr.write(
        "python-pptx is required. Install with: "
        "python3 -m pip install --user python-pptx\n"
    )
    raise SystemExit(1) from e

logging.basicConfig(format="%(levelname)s %(message)s", level=logging.INFO)
log = logging.getLogger("generate-deck")


# ---------------------------------------------------------------------------
# Slide content
# ---------------------------------------------------------------------------
#
# Layouts referenced below (see _log_layouts output for the full catalogue):
#   "Title Only 1"
#   "Title, Subtitle Only 1"
#   "Title, 1 Column with Bullets"
#   "Title, 2 Columns with Bullets"
#   "Title, Subtitle, 2 Columns"
#   "Title, Subtitle, 3 Columns"
#   "Title, Subtitle, Table 1"
#   "Statement 1, Title, Subtitle"
#   "Quote 1"
#   "Segue 1"
#   "Thank you 1"
#
# Placeholder indices vary by layout; we populate by index, not by name,
# because names like "Text Placeholder 4" are not stable across layouts.
# When a layout includes placeholders for things we don't have (e.g. a
# CHART placeholder), we leave them untouched and the template's fallback
# rendering handles it.


@dataclass
class Slide:
    """Declarative slide spec."""

    layout: str
    placeholders: dict[int, str | list[str]] = field(default_factory=dict)
    notes: str = ""


ENGINEER_SLIDES: list[Slide] = [
    # -------------------------------------------------------------------
    # 1 — Title slide. The "Statement" layout is the cleanest big-text
    # opener in the Splunk deck; placeholder 0 is the headline, 11 is the
    # subtitle line.
    # -------------------------------------------------------------------
    Slide(
        layout="Statement 1, Title, Subtitle",
        placeholders={
            0: "Observability without seams",
            11: "NatWest Payment Platform on Splunk Observability Cloud",
        },
        notes=(
            "Open in front of Splunk Observability Cloud, with the SPA "
            "loaded in a second tab and the demo cluster reachable. "
            "Don't talk through the title — frame the room with 'a "
            "customer just complained their payment is slow' and pivot."
        ),
    ),

    # 2 — Capability matrix (Hook).
    Slide(
        layout="Title, Subtitle, Table 1",
        placeholders={
            0: "What you're about to see",
            11: "One trace ID. One investigation. Six product surfaces.",
        },
        notes=(
            "Hook slide. Don't enumerate every row — pick two and tease "
            "the rest. ('RUM ties the customer click to the trace; "
            "AlwaysOn Profiling lands on the line of code.') The matrix "
            "returns at the end as a bracket."
        ),
    ),

    # 3 — Architecture / scope.
    Slide(
        layout="Title, 1 Column with Bullets",
        placeholders={
            0: "The platform under the lens",
            12: [
                "24 microservices, polyglot — Java ledger-service, "
                "Python everywhere else. Splunk Distribution of OTel.",
                "Real data plane — Postgres for the ledger, Redis for "
                "sanctions cache, Kafka for settlement fan-out.",
                "Six channels (mobile, online, branch, bankline, "
                "bankline-direct, partner-api).",
                "Six payment schemes — FPS 60%, BACS 15%, CHAPS 8%, "
                "SEPA 8%, SWIFT 6%, Cheque 3%.",
                "Realistic shape — country-pair spreads, time-of-day "
                "RPS curve, periodic error bursts.",
            ],
        },
        notes=(
            "The credibility slide. Real EKS, real Postgres / Redis / "
            "Kafka, simulated business logic. Without this slide the "
            "audience suspects a canned demo."
        ),
    ),

    # 4 — Act I segue.
    Slide(
        layout="Segue 1",
        placeholders={
            0: "Act I — A six-minute investigation",
        },
        notes=(
            "Pre-arm the incident ~3 min before stage time:\n"
            "  scripts/incident.sh fraud-cpu-regression\n"
            "Run-flow reminder for live sessions:\n"
            "  scripts/00-provision.sh -> 01-build-push.sh -> "
            "02-install-collector.sh -> 03-deploy.sh -> "
            "04-start-traffic.sh -> 05-deploy-frontend.sh -> "
            "05b-frontend-public-proxy.sh\n"
            "AlwaysOn Profiling needs the time to sample both baselines."
        ),
    ),

    # 5 — Act I overview.
    Slide(
        layout="Title, 1 Column with Bullets",
        placeholders={
            0: "Act I — six minutes, one trace ID",
            12: [
                "1. Customer click — RUM Sessions  (60s)",
                "2. Slow span — APM Trace  (75s)",
                "3. The log line — Logs in Context  (45s)",
                "4. The line of code — AlwaysOn Profiling  (90s)",
                "5. Recover — `incident.sh recover`  (30s)",
                "RUM → APM → Log → Profile → commit. One investigation, "
                "five surfaces.",
            ],
        },
        notes=(
            "Don't read the table aloud. Point at it as you walk. "
            "Hold the timing — anyone who's been on call recognises "
            "the cadence."
        ),
    ),

    # 6 — Act I.1 RUM.
    Slide(
        layout="Title, 1 Column with Bullets",
        placeholders={
            0: "Act I · 1 — Customer click  (RUM)",
            12: [
                "Open the SPA, submit one SWIFT payment. Click feels "
                "slower than baseline.",
                "RUM → Sessions: page-action span carries `traceparent` "
                "via W3C trace context.",
                "One click → APM Trace.",
                "Tell: 'We never asked the user anything; the SDK "
                "handed us the trace.'",
                "Ask Beat: 'How long does it take your team today to go "
                "from a complaint to the trace?'",
            ],
        },
        notes=(
            "Common landing time is '20 minutes to an hour' in regulated "
            "banks. Use the silence. This is the only moment in Act I "
            "where a pause is truly required."
        ),
    ),

    # 7 — Act I.2 APM.
    Slide(
        layout="Title, 1 Column with Bullets",
        placeholders={
            0: "Act I · 2 — Slow span  (APM)",
            12: [
                "Trace tree: web-frontend → api-gateway → "
                "payment-initiation → fraud-detection.",
                "Stop on fraud-detection. `compute_fraud_features` is "
                "the new CPU-bound child span.",
                "Business attributes on the span — `fraud.algo = pairwise`, "
                "`fraud.feature_count = 96`. First-class, pivot-able data.",
                "Side-quest: `ledger-service` JDBC spans show "
                "`db.statement = INSERT INTO ledger_entry …` — "
                "DB Query Performance, no Postgres exporter.",
                "Tell: 'Hypothesis live — fraud-detection. Now I want "
                "the log line that this code wrote, on this trace.'",
            ],
        },
        notes=(
            "DB Query Performance is a free side-quest here. Don't "
            "dwell — point at the JDBC statements and say 'this is its "
            "own product surface; we're coming back to it in Act II.'"
        ),
    ),

    # 8 — Act I.3 LOC.
    Slide(
        layout="Title, 1 Column with Bullets",
        placeholders={
            0: "Act I · 3 — Logs in Context  (LOC)",
            12: [
                "Same span → Logs for this trace.",
                "Returns the structured JSON line from "
                "fraud-detection-service: `service`, `level`, "
                "`trace_id`, `span_id`, `payment_id`, "
                "`payment.scheme = SWIFT`.",
                "Pipeline — container logs ship via Splunk OTel "
                "Collector to in-VPC Splunk Enterprise (HEC 8088); "
                "Log Observer Connect federates them into o11y.",
                "Architectural point — your existing Splunk Enterprise "
                "estate becomes the log backplane. No re-platform.",
                "Ask Beat: 'Where does that pivot live in your stack "
                "today, and how many context switches does it cost?'",
            ],
        },
        notes=(
            "This is the LOC reveal. Visually it's one click in APM, "
            "but the architectural point matters: customer's existing "
            "Splunk indexers reused as-is."
        ),
    ),

    # 9 — Act I.4 Profiling.
    Slide(
        layout="Title, 1 Column with Bullets",
        placeholders={
            0: "Act I · 4 — Line of code  (AlwaysOn Profiling)",
            12: [
                "Same APM span → AlwaysOn Profiling → CPU flame graph.",
                "Hot stack: `_extract_features_pairwise` inside "
                "`compute_fraud_features`.",
                "Profiling diff — last 5 min vs. baseline. The new "
                "tower is unmistakable.",
                "Continuous sampling of every JVM and Python process, "
                "in production, ~1% CPU overhead.",
                "Tell: 'Not just \"fraud-detection regressed\" but "
                "which line of which file regressed it.'",
            ],
        },
        notes=(
            "Climax of Act I. Slow down. The flame graph diff is the "
            "most visually dense panel in the demo — give it time. "
            "Then run incident.sh recover to bracket the moment."
        ),
    ),

    # 10 — Act I.5 Recover (quote layout for emphasis).
    Slide(
        layout="Quote 1",
        placeholders={
            0: (
                "RUM → Trace → Log → Profile, in six minutes, on one "
                "page. Same data plane, same dimensions, same trace ID. "
                "That's what a NatWest engineer's Tuesday afternoon "
                "should look like."
            ),
            12: "Bracket — return to the capability matrix",
        },
        notes=(
            "After running scripts/incident.sh recover. Watch p99 "
            "settle, regression tower disappears, customer click times "
            "return. Pause. Absorb 2-3 minutes of discussion before "
            "moving to Act II."
        ),
    ),

    # 11 — Act II segue.
    Slide(
        layout="Segue 2",
        placeholders={
            0: "Act II — The breadth tour",
        },
        notes=(
            "~12 minutes. Each section is short — heavy lifting is done. "
            "Keep the room moving."
        ),
    ),

    # 12 — Act II.A Service Map.
    Slide(
        layout="Title, 1 Column with Bullets",
        placeholders={
            0: "Act II · A — Service map",
            12: [
                "24 services auto-discovered from OTel spans. Zero "
                "per-service tracing PRs.",
                "Postgres, Redis, Kafka are first-class service nodes. "
                "infra-heartbeat emits one synthetic span/min/backend.",
                "The same nodes carry infrastructure metrics (memory, "
                "evictions, broker latency, pg_stat) and pod logs.",
                "Polyglot mesh — Java ledger-service mid-fleet, Python "
                "everywhere else, no visual seam.",
                "Click Postgres twice: DB Query Performance, then Logs. "
                "Same model, multiple pivots.",
                "Ask Beat: 'When was the last time you saw your "
                "payments topology like this — channel through scheme, "
                "with the data plane in the same picture?'",
            ],
        },
        notes=(
            "Repeat Postgres/Kafka pivots to land the broker-side "
            "metrics story (request p99, ISR shrinks)."
        ),
    ),

    # 13 — Act II.B Tag Spotlight (2-column).
    Slide(
        layout="Title, 2 Columns with Bullets",
        placeholders={
            0: "Act II · B — Tag Spotlight",
            14: [
                "Pivot by `payment.scheme`",
                "SWIFT highest p99 + error rate.",
                "Pivot by `customer.tier` (Bronze/Silver/Gold)",
                "Gold p95 below Bronze (fraud fast-path); "
                "Bronze decline rate is the throttle canary.",
                "Pivot by `country_pair`",
                "Operational pain has geographic shape.",
            ],
            15: [
                "Every span carries business context.",
                "'Which customer tier is hit hardest right now?' is a "
                "pivot, not a JIRA ticket for the data team.",
                "Ask Beat: 'If your VP of Payments asked which scheme "
                "is hurting which tier right now, how long would it "
                "take you to answer?'",
            ],
        },
        notes=(
            "The differentiator slide for non-technical audiences. "
            "When a payments-ops VP sees scheme + tier as "
            "first-class dimensions, the room turns. Linger longer "
            "than the breadth slide."
        ),
    ),

    # 14 — Act II.C Detectors.
    Slide(
        layout="Title, 1 Column with Bullets",
        placeholders={
            0: "Act II · C — Detectors, SLOs, Synthetics",
            12: [
                "Run `scripts/incident.sh swift-counterparty-flap`.",
                "Detectors → Active Alerts: `[NatWest demo] SWIFT "
                "error rate` fires Critical in ~30s.",
                "Alert detail → threshold band → runbook URL.",
                "Synthetic Monitoring: per-minute results show the "
                "spike and the recovery.",
                "Optional cycle: `incident.sh cache-cold` / "
                "`db-slow` — catalogue of failure modes.",
                "Tell: 'Detectors don't replace your eyes — they buy "
                "them back. The team sleeps; the platform watches.'",
            ],
        },
        notes=(
            "Run swift-counterparty-flap mid-presentation. ~30s "
            "propagation gives you time to walk through dashboards "
            "while it lands."
        ),
    ),

    # 15 — Act II.D Infra metrics + ITSI roll-up.
    Slide(
        layout="Title, 1 Column with Bullets",
        placeholders={
            0: "Act II · D — Infra metrics & ITSI roll-up",
            12: [
                "Splunk Observability Infrastructure: Redis/Postgres/"
                "Kafka navigators auto-populate when collector lights up.",
                "Memory, evictions, broker latency, replication health, "
                "query stats — no hand-rolled integration.",
                "ITSI Service Analyzer: same metrics drive "
                "nwpay_l4_redis / nwpay_l4_postgres / nwpay_l4_kafka.",
                "One walk: kill Redis pod → map red, infra drops, ITSI "
                "L4 critical, sanctions cache miss warning, detector fires.",
                "Tell: 'Same data plane that pinned one slow span now "
                "answers broker health with shared dimensions.'",
            ],
        },
        notes=(
            "Bridge APM-only customers into Splunk Observability + ITSI. "
            "Optional chaos: kubectl delete pod redis -n natwest."
        ),
    ),

    # 16 — Act II.E Synthetic monitoring + DCE.
    Slide(
        layout="Title, 1 Column with Bullets",
        placeholders={
            0: "Act II · E — Synthetic monitoring & Digital Customer Experience",
            12: [
                "ThousandEyes -> Splunk add-on: 6 synthetic tests from 5 "
                "geos (HTTP, browser, transaction, DNS, API write).",
                "ITSI L2 Digital Customer Experience tier: 7 synthetic KPIs "
                "weighted into nwpay_l2_dce and nwpay_l1.",
                "Red RUM + green DCE -> likely real-user/ISP issue.",
                "Green RUM + red DCE -> synthetic catches it before "
                "customers report it.",
                "Both red -> drill to failing TE test, then to "
                "index=thousandeyes event for network triage.",
            ],
        },
        notes=(
            "Optional for ITSI-mature audiences. Skip silently if TE data "
            "is still bootstrapping."
        ),
    ),

    # 17 — Act II.F Dashboard.
    Slide(
        layout="Title, 1 Column with Bullets",
        placeholders={
            0: "Act II · F — Dashboard",
            12: [
                "Dashboards → `[NatWest demo] Payments Operations`.",
                "RPS by scheme — the time-of-day curve.",
                "p99 latency by scheme — SWIFT and CHAPS lead, FPS "
                "dominates volume.",
                "Cache hit ratio — dips during cache-cold.",
                "GBP volume processed — the VP-of-Payments single number.",
                "Run `scripts/incident.sh recover`. Numbers heal in real time.",
            ],
        },
        notes=(
            "End on the GBP volume number. That's the single metric a "
            "non-technical sponsor remembers."
        ),
    ),

    # 18 — Capability matrix (bracket back to slide 2).
    Slide(
        layout="Title, Subtitle, Table 1",
        placeholders={
            0: "Splunk's edge — what you saw",
            11: (
                "Same matrix as the opening — every row now anchored "
                "to a panel you watched land."
            ),
        },
        notes=(
            "Bracket the opening; do not introduce new capabilities. "
            "If asked to expand, use the Why-this-matters slide next."
        ),
    ),

    # 19 — Why this matters.
    Slide(
        layout="Title, 1 Column with Bullets",
        placeholders={
            0: "Why this matters",
            12: [
                "Mean time to context collapses — minutes, not change "
                "tickets.",
                "Single backplane — RUM, APM, Profiling, Logs, "
                "Synthetics, Infra share dimensions and trace IDs.",
                "Existing Splunk estate is reused — LOC means logs "
                "stay where they are, governance untouched.",
                "Polyglot is a non-event — Java + Python today; Go or "
                ".NET joins for free.",
                "Business-first attributes — payments-ops, fraud-ops, "
                "and engineering all read the same screen.",
            ],
        },
        notes=(
            "Executive landing slide. Address the CTO/CIO/COO line "
            "directly. Resist the urge to talk about cost — the moment "
            "you do, the conversation turns into procurement."
        ),
    ),

    # 20 — Objections (3-column for tight density).
    Slide(
        layout="Title, Subtitle, 3 Columns",
        placeholders={
            0: "Common objections",
            11: "Anchor every response in something they just watched.",
            13: [
                "We have ELK / Datadog / Dynatrace.",
                "Same trace ID end-to-end. Business attributes "
                "first-class. LOC keeps existing log estate.",
                "",
                "Profiling will eat my CPU.",
                "~1% overhead. AlwaysOn samples continuously, you saw "
                "the diff land.",
            ],
            14: [
                "OTel rollout is a multi-quarter program.",
                "You watched 24 polyglot services that were "
                "instrumented by deployment alone.",
                "",
                "We can't expose PII as span attributes.",
                "Tags are dimensions you opt into. No PAN, no name, no "
                "PII in any span we showed.",
            ],
            15: [
                "Our log estate is on Splunk Enterprise.",
                "You don't move it. LOC federates it into o11y. Same "
                "indexers, same retention, same governance.",
                "",
                "What about cost?",
                "Architecture choice doesn't change with licensing. "
                "Walk through with your AE on a separate motion.",
            ],
        },
        notes=(
            "Keep on screen for objection cycling. If a question maps "
            "to a column, answer using the panel they saw — never "
            "abstract."
        ),
    ),

    # 21 — Champion brief.
    Slide(
        layout="Title, 1 Column with Bullets",
        placeholders={
            0: "Champion brief — paste-ready",
            12: [
                "EKS-hosted, 24-service simulation of NatWest's payment "
                "topology — 6 channels, 6 schemes, polyglot, real "
                "Postgres / Redis / Kafka.",
                "In 6 minutes, Splunk Observability Cloud takes a "
                "customer's slow click in RUM through APM, Logs in "
                "Context, and AlwaysOn Profiling to the regressed line "
                "of code — ~1% CPU overhead in production.",
                "Cluster is in the same VPC as our Splunk Enterprise "
                "instance. No log re-platform required.",
                "Splunk ITSI/Web: https://itsi.splunk-observability.com:8000. "
                "Observability Cloud: https://app.<realm>.signalfx.com.",
                "Ask: 60-minute technical deep-dive against your real "
                "services with your SRE / payments-ops leads.",
            ],
        },
        notes=(
            "Read the champion brief aloud once - it's the paragraph "
            "you want them to forward internally. Then pivot to the "
            "60-minute follow-up ask. Don't pitch licensing."
        ),
    ),

    # 22 — Access details.
    Slide(
        layout="Title, 2 Columns with Bullets",
        placeholders={
            0: "Access details (operator quick links)",
            14: [
                "Splunk ITSI / Splunk Web:",
                "https://itsi.splunk-observability.com:8000/en-US/app/itsi",
                "Auth: admin + TF_VAR_splunk_enterprise_admin_password",
                "(demo default may be smartway).",
            ],
            15: [
                "Splunk Observability Cloud:",
                "https://app.<realm>.signalfx.com",
                "Terraform inputs:",
                "TF_VAR_splunk_realm, TF_VAR_splunk_access_token,",
                "TF_VAR_splunk_api_token.",
                "Keep credentials out of slides; use env vars + SSO.",
            ],
        },
        notes=(
            "Operational framing, not a sales beat. Keep to 20-30 seconds."
        ),
    ),

    # 23 — Closing / thank you.
    Slide(
        layout="Thank you 1",
        placeholders={
            0: "Thank you",
        },
        notes=(
            "Hold this slide while Q&A continues. If asked for the "
            "Splunk Enterprise login: admin / smartway, restricted to "
            "operator IPs in the SG."
        ),
    ),
]


# ---------------------------------------------------------------------------
# Exec / top-down profile (30-minute C-level cut)
# ---------------------------------------------------------------------------
#
# Mirrors `docs/presentation/EXEC_DEMO_30MIN_TOPDOWN.md` beat-for-beat. The
# narrative arc is two woven threads: a pre-armed SWIFT incident (depth)
# and a live mid-demo Madrid inject (breadth), so the Glass Table is alive
# when the audience walks in and visibly updates while we narrate.

EXEC_TOPDOWN_SLIDES: list[Slide] = [
    # -------------------------------------------------------------------
    # 1 - Title.
    # -------------------------------------------------------------------
    Slide(
        layout="Statement 1, Title, Subtitle",
        placeholders={
            0: "When the COO opens the Glass Table",
            11: (
                "NatWest Payment Platform — 30-minute top-down "
                "walkthrough"
            ),
        },
        notes=(
            "Pre-flight before this slide goes up:\n"
            "  T-15  arm swift-counterparty-flap via /ops (or "
            "`scripts/incident.sh swift-counterparty-flap`).\n"
            "  T-12  hard-refresh the Overview Glass Table tab; "
            "confirm the SWIFT episode is visible in the Notable "
            "Events panel.\n"
            "  T-5   open tabs left-to-right: (1) Glass Table, "
            "(2) ITSI Episode Review, (3) APM Service Map, (4) RUM "
            "Overview, (5) /ops Chaos Dashboard (LAST), (6) SLOs.\n"
            "  T-2   ?presenter=1 on the SPA, secondary screen only.\n"
            "Companion runbook: docs/presentation/"
            "EXEC_DEMO_30MIN_TOPDOWN.md."
        ),
    ),
    # 2 - Hook.
    Slide(
        layout="Statement 1, Title, Subtitle",
        placeholders={
            0: "Two incidents. One platform. Zero context switches.",
            11: (
                "Glass Table → ITSI episode → APM root cause → live "
                "inject → RUM → SLO burn — all in 30 minutes."
            ),
        },
        notes=(
            "Don't enumerate every surface. Tease the structure: "
            "'a COO sees the business; an SRE sees the line of code; "
            "the customer never has to call.' Then pivot straight to "
            "the Glass Table tab."
        ),
    ),
    # 3 - Platform under the lens (credibility).
    Slide(
        layout="Title, 1 Column with Bullets",
        placeholders={
            0: "The platform under the lens",
            12: [
                "24 microservices on EKS — polyglot. Java ledger, "
                "Python everywhere else. Splunk Distribution of OTel.",
                "Real data plane — Postgres ledger, Redis sanctions "
                "cache, Kafka settlement fan-out.",
                "Six channels, six schemes — FPS 60%, BACS 15%, "
                "CHAPS 8%, SEPA 8%, SWIFT 6%, Cheque 3%.",
                "End-to-end Splunk Observability Cloud (RUM, APM, "
                "Logs, SLOs) + ITSI + Cisco ThousandEyes.",
                "Everything on screen for the next 30 minutes is "
                "live data from the last 60 seconds.",
            ],
        },
        notes=(
            "The credibility slide. Without it the audience suspects "
            "a canned demo. 30 seconds, then move."
        ),
    ),
    # 4 - Part 1 segue.
    Slide(
        layout="Segue 1",
        placeholders={
            0: "Part 1 — Top down from the COO's chair",
        },
        notes=(
            "Two beats: 'business health in one screen' then 'red "
            "tile to root cause in six minutes.'"
        ),
    ),
    # 5 - 0:02 - 0:07 Overview Glass Table.
    Slide(
        layout="Title, 1 Column with Bullets",
        placeholders={
            0: "0:02–0:07 · Overview Glass Table  (ITSI #1)",
            12: [
                "Top KPI row — Payments/min, Value authorised (GBP), "
                "Customers impacted, GBP at risk, Success rate.",
                "L1 / L2 / Tier health — one root score, nine "
                "capability tiles, three customer tiers "
                "(Bronze/Silver/Gold).",
                "Geography row — destinations, customer origin, "
                "payments by city. 1.2M payments/day, no SPL written.",
                "Tier transaction split + Decline rate by tier — Gold "
                "lower decline than Bronze (wealth-management point).",
                "Active payments incident — notable events panel: "
                "SWIFT episode is already there. 'Let me show you "
                "what ITSI did with that.'",
            ],
        },
        notes=(
            "Anchor file: itsi/glass-table/natwest-payments-overview"
            ".xml. Walk panels top-to-bottom; never leave the Glass "
            "Table during this section. The Active payments incident "
            "panel is the pivot - pause before clicking the episode."
        ),
    ),
    # 6 - 0:07 - 0:10 ITSI Episode Review + Service Analyser.
    Slide(
        layout="Title, 1 Column with Bullets",
        placeholders={
            0: "0:07–0:10 · ITSI Episode Review  (ITSI #2)",
            12: [
                "Click the SWIFT episode → Episode Review. One "
                "episode, one timeline.",
                "Aggregates Splunk Observability detectors, audit "
                "events from the payments log, and chaos markers if "
                "an SRE was experimenting.",
                "Correlation search: itsi/correlation-searches/"
                "o11y_to_itsi.json. Aggregation policy: itsi/"
                "aggregation-policies/payments_episode_policy.json.",
                "'This isn't magic - it's a 30-line rule the ops "
                "team owns.'",
                "Drill: Service Analyser for nwpay_l3_swift_network → "
                "KPIs trending → click into APM.",
            ],
        },
        notes=(
            "30 seconds on the correlation search file is enough - "
            "the point is that the rule is human-readable, not that "
            "we walk it. Move on to Service Analyser quickly."
        ),
    ),
    # 7 - 0:10 - 0:16 APM root cause (deepest segment).
    Slide(
        layout="Title, 1 Column with Bullets",
        placeholders={
            0: "0:10–0:16 · APM root cause  (Observability #1)",
            12: [
                "Service map — 24 services, inferred Postgres / Redis "
                "/ Kafka, async settlement via Kafka edge, all from "
                "traces. swift-network is red.",
                "Tag Spotlight on api-gateway, filter "
                "payment.scheme=SWIFT. Business tags (customer.tier, "
                "payment.scheme, customer.location, payment.roaming) "
                "are first-class metrics. scripts/lib/metricsets.json.",
                "Failing trace → waterfall: api-gateway → "
                "payment-initiation → routing → swift-network. The "
                "swift-network span is red, with error attributes.",
                "Logs in Context → 'view logs' on the swift-network "
                "span. Splunk Enterprise federation resolves trace ID "
                "to the application log line. One platform, one bill.",
                "Root cause in one line — 'swift-network is returning "
                "5xx for 30% of payments. The SRE knows what to roll "
                "back without leaving Splunk.'",
            ],
        },
        notes=(
            "The deepest segment. Slow down on Tag Spotlight - it's "
            "the differentiator vs. ELK/Datadog/Dynatrace for "
            "payments-ops audiences. The Logs-in-Context click is the "
            "moment that lands the federation story: same trace ID "
            "resolves both ways."
        ),
    ),
    # 8 - 0:16 - 0:17 Live chaos inject (emphasis with quote layout).
    Slide(
        layout="Quote 1",
        placeholders={
            0: (
                "For the next four minutes the platform will catch a "
                "brand-new incident in Madrid while we're looking "
                "elsewhere. Let's see who notices first — me, or Splunk."
            ),
            12: "0:16–0:17 · Live inject — madrid-network-degradation",
        },
        notes=(
            "Pop to /ops. Briefly. 'Here's the demo control panel - "
            "it's also what your SRE team uses for game-days.' Click "
            "Inject on madrid-network-degradation. Confirm the row "
            "flips to Active on the Presenter HUD within ~2s. Then "
            "move to RUM. Anchor files: frontend/src/pages/Ops.tsx, "
            "chaos-controller/app/scenarios.py.\n"
            "Keyboard fallback if the /ops button silently fails:\n"
            "  curl -fsS -X POST \\\n"
            "       -H \"X-Chaos-Token: $CHAOS_PRESENTER_TOKEN\" \\\n"
            "       -H 'Content-Type: application/json' -d '{}' \\\n"
            "       \"$SPA_URL/chaos/api/madrid-network-degradation/inject\""
        ),
    ),
    # 9 - Part 2 segue.
    Slide(
        layout="Segue 2",
        placeholders={
            0: "Part 2 — Breadth, customer side",
        },
        notes=(
            "Three beats: customer-side same incident (RUM), "
            "second incident lights up (ITSI breadth + ThousandEyes), "
            "business impact (SLO burn)."
        ),
    ),
    # 10 - 0:17 - 0:21 RUM / Digital Experience Analytics.
    Slide(
        layout="Title, 1 Column with Bullets",
        placeholders={
            0: "0:17–0:21 · RUM & Digital Experience  (Observability #2)",
            12: [
                "RUM Overview for natwest-payments-web. Live session "
                "count, by tier and country.",
                "Tag Spotlight by customer.tier → Bronze SPA failure "
                "rate spike. Detector: [NatWest demo] Bronze SPA "
                "failure rate (terraform/observability.tf).",
                "Frustration Signals — rage-clicks on the failed-"
                "SWIFT Retry button. 'The customer never raised a "
                "ticket. Splunk saw them get angry.'",
                "Anchor: frontend/src/rum.ts, "
                "frustrationSignals: { rageClick, deadClick, "
                "errorClick }.",
                "Journey replay available, privacy-aware, masking "
                "rules per session class.",
            ],
        },
        notes=(
            "The empathy slide. The COO understands rage-clicks "
            "intuitively. Don't over-explain - show the cluster of "
            "red dots on the Retry button and let the panel speak."
        ),
    ),
    # 11 - 0:21 - 0:25 Madrid episode + ThousandEyes.
    Slide(
        layout="Title, 2 Columns with Bullets",
        placeholders={
            0: "0:21–0:25 · Madrid lights up  (ITSI breadth + Cisco One)",
            14: [
                "Switch back to the Overview Glass Table.",
                "New episode in the Notable Events panel.",
                "Detector: [NatWest demo] Madrid p95 latency "
                "(terraform/observability.tf).",
                "Correlation search: itsi/correlation-searches/"
                "payments_madrid_latency_breach.json.",
                "ITSI didn't conflate it with SWIFT. Didn't email "
                "anyone twice.",
            ],
            15: [
                "Pivot to ThousandEyes panels (bottom of Glass Table) — "
                "Network loss %, Network latency by agent, "
                "Reachability by region.",
                "Test payloads: scripts/lib/te_test_payloads/.",
                "'Cisco One in action. Outside-in network "
                "observability in the same Glass Table - no "
                "second tool.'",
                "Optional flash: open Madrid episode → Service "
                "Analyser for nwpay_l2_payment_by_location. Madrid "
                "KPI breached, London/Frankfurt/Paris/Milan green.",
            ],
        },
        notes=(
            "The breadth payoff. The audience now sees that the same "
            "platform caught a completely different incident class in "
            "a completely different geography while we were looking "
            "at RUM. Land the ThousandEyes integration explicitly - "
            "this is the Cisco One differentiator."
        ),
    ),
    # 12 - 0:25 - 0:27 SLO burn + close (quote for emphasis).
    Slide(
        layout="Quote 1",
        placeholders={
            0: (
                "The COO would have known. The SRE would have known "
                "root cause in six minutes. The customer never had "
                "to call."
            ),
            12: "0:25–0:27 · SLO burn + close",
        },
        notes=(
            "Glass Table → SLO 1h fast-burn panel + Active SLO "
            "breach episodes. SLO definitions: terraform/"
            "observability_slos.tf. Land the three-sentence close "
            "verbatim. Then recover all chaos in one click from "
            "/ops (or `make chaos-recover`) so panels heal live "
            "while Q&A starts."
        ),
    ),
    # 13 - Why this matters (exec landing).
    Slide(
        layout="Title, 1 Column with Bullets",
        placeholders={
            0: "Why this matters",
            12: [
                "Mean time to context collapses — Glass Table to "
                "root cause in single-digit minutes, not change "
                "tickets.",
                "One backplane — ITSI, RUM, APM, Logs, SLOs, "
                "ThousandEyes share dimensions and trace IDs.",
                "Existing Splunk Enterprise estate is reused — "
                "Logs in Context federates the audit log; no "
                "log re-platform.",
                "Business attributes are first-class — payments-ops, "
                "fraud-ops, and engineering all read the same screen.",
                "Cisco One in the same Glass Table — outside-in "
                "ThousandEyes alongside the app blame, no "
                "context-switch to a second tool.",
            ],
        },
        notes=(
            "Executive landing slide. Address the CTO/CIO/COO line "
            "directly. Resist the urge to talk about cost - the "
            "moment you do, the conversation turns into procurement."
        ),
    ),
    # 14 - Capability coverage table (bracket).
    Slide(
        layout="Title, Subtitle, Table 1",
        placeholders={
            0: "What you watched — capability coverage",
            11: (
                "Every Splunk + Cisco surface anchored to a panel you "
                "watched land in the last 30 minutes."
            ),
        },
        notes=(
            "Mirror of EXEC_DEMO_30MIN_TOPDOWN.md 'Splunk capability "
            "coverage at a glance' table:\n"
            "  ITSI Glass Tables                          0:02-0:07, "
            "0:21-0:25\n"
            "  ITSI Service tree + KPI rollup             0:02-0:07\n"
            "  ITSI Episodes + correlation searches       0:07-0:10, "
            "0:21-0:25\n"
            "  ITSI Service Analyser                      0:07-0:10, "
            "0:21-0:25\n"
            "  APM service map                            0:10-0:16\n"
            "  APM Tag Spotlight + MetricSets             0:10-0:16\n"
            "  APM trace + Logs in Context                0:10-0:16\n"
            "  APM Detectors (SWIFT, Madrid, Bronze)      throughout\n"
            "  RUM + DXA + Frustration Signals            0:17-0:21\n"
            "  SLOs + burn-rate alerting                  0:25-0:27\n"
            "  ThousandEyes / Cisco One                   0:21-0:25\n"
            "  Live game-day controls (/ops)              0:16-0:17"
        ),
    ),
    # 15 - Common objections (exec-flavoured).
    Slide(
        layout="Title, Subtitle, 3 Columns",
        placeholders={
            0: "Exec-level objections",
            11: "Anchor every response in something they just watched.",
            13: [
                "Aren't we already running ELK / Datadog / Dynatrace?",
                "You saw one trace ID flow from RUM through APM into "
                "the Splunk Enterprise log - no second tool, no "
                "second bill, no re-platform.",
                "",
                "What about lock-in?",
                "OpenTelemetry on the wire. If you ever swap the "
                "backend, the instrumentation stays.",
            ],
            14: [
                "ThousandEyes is a Cisco tool — won't that mean two "
                "vendors?",
                "Cisco One — the ThousandEyes panels live inside the "
                "ITSI Glass Table you watched. One pane of glass, one "
                "renewal cycle.",
                "",
                "Where does the data live?",
                "Splunk Observability in EU0; Splunk Enterprise on "
                "your AWS account in your chosen region. No PII in "
                "any span we showed.",
            ],
            15: [
                "Cost?",
                "Architecture choice doesn't change with licensing. "
                "Per-million-payments ingest number on a separate "
                "motion with your AE.",
                "",
                "Adoption risk?",
                "24 polyglot services were instrumented by deployment "
                "alone. Same for your real estate.",
            ],
        },
        notes=(
            "Keep on screen for objection cycling. If a question maps "
            "to a column, answer using the panel they saw - never "
            "abstract. If asked about regulator / data residency, "
            "anchor on 'Splunk Observability in EU0' and offer to "
            "follow up on certifications in writing."
        ),
    ),
    # 16 - Champion brief (paste-ready).
    Slide(
        layout="Title, 1 Column with Bullets",
        placeholders={
            0: "Champion brief — paste-ready",
            12: [
                "EKS-hosted, 24-service simulation of NatWest's "
                "payment topology — 6 channels, 6 schemes, polyglot, "
                "real Postgres / Redis / Kafka.",
                "In 30 minutes, Splunk + Cisco One takes a COO from "
                "the Overview Glass Table through ITSI Episodes into "
                "Splunk Observability APM, RUM, SLOs, and Cisco "
                "ThousandEyes — all on the same trace ID.",
                "Two woven incidents — a SWIFT counterparty flap "
                "and a Madrid network degradation — caught and "
                "triaged with no second tool.",
                "Existing Splunk Enterprise estate becomes the "
                "log backplane via Logs in Context — no re-platform.",
                "Ask: 60-minute working session against your real "
                "topology with payments-ops, SRE, and the platform "
                "leader.",
            ],
        },
        notes=(
            "Read the champion brief aloud once - this is the "
            "paragraph you want them to forward internally. Then "
            "pivot to the 60-minute follow-up ask. Don't pitch "
            "licensing."
        ),
    ),
    # 17 - Thank you / Q&A buffer.
    Slide(
        layout="Thank you 1",
        placeholders={
            0: "Thank you",
        },
        notes=(
            "Hold on the Glass Table tab (not this slide) during "
            "Q&A so panels stay visible. While Q&A starts, recover "
            "all chaos: `make chaos-recover` (or click Recover on "
            "/ops). Panels heal live - 'and the platform recovers "
            "as cleanly as it failed' is the quiet final beat."
        ),
    ),
]


# ---------------------------------------------------------------------------
# Profiles
# ---------------------------------------------------------------------------

# `SLIDES` is kept as a back-compat alias so external references in the
# README and any imports continue to resolve. The default profile is the
# engineer/bottom-up cut to preserve existing behaviour.
SLIDES = ENGINEER_SLIDES

PROFILES: dict[str, list[Slide]] = {
    "engineer": ENGINEER_SLIDES,
    "exec-topdown": EXEC_TOPDOWN_SLIDES,
}

DEFAULT_OUTPUTS: dict[str, str] = {
    "engineer": "docs/presentation/slides.pptx",
    "exec-topdown": "docs/presentation/slides-exec-topdown.pptx",
}


# ---------------------------------------------------------------------------
# Generation logic
# ---------------------------------------------------------------------------


def _layouts_by_name(prs: Presentation) -> dict[str, Any]:
    """Return a {layout_name: layout_obj} map across all masters."""
    out: dict[str, Any] = {}
    for master in prs.slide_masters:
        for layout in master.slide_layouts:
            out[layout.name] = layout
    return out


def _strip_existing_slides(prs: Presentation) -> None:
    """Remove every slide currently in the presentation, leaving masters
    and layouts intact.

    python-pptx doesn't expose slide deletion publicly, so we drop the
    sldId entry and the matching relationship by hand. `prs.part.rels`
    is a custom `_Relationships` collection that does *not* implement
    dict.pop(key, default); use `del` and key membership instead.
    """
    REL_NS = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id"
    sldIdLst = prs.slides._sldIdLst  # noqa: SLF001 - python-pptx idiom
    # _Relationships is dict-like but only supports `pop(rId)` (single arg)
    # and exposes the underlying mapping as `_rels`. The supported pop()
    # raises on missing keys, so we go through the internal dict to be
    # tolerant if the sldIdLst is ever out of sync with the rel table.
    rels_dict = prs.part.rels._rels  # noqa: SLF001 - python-pptx internal
    for sld_id in list(sldIdLst):
        rId = sld_id.attrib[REL_NS]
        rels_dict.pop(rId, None)
        sldIdLst.remove(sld_id)


def _set_text(placeholder: Any, value: str | list[str]) -> None:
    """Set a placeholder's text frame to either a single string or a
    bulleted list. We touch text only; sizing/colour is inherited from
    the layout."""
    if not placeholder.has_text_frame:
        log.debug("placeholder %s is not a text frame; skipping", placeholder.name)
        return
    tf = placeholder.text_frame
    tf.clear()
    if isinstance(value, str):
        tf.paragraphs[0].text = value
        return
    for i, item in enumerate(value):
        if i == 0:
            tf.paragraphs[0].text = item
        else:
            p = tf.add_paragraph()
            p.text = item


def _add_notes(slide: Any, notes: str) -> None:
    """Replace the slide's presenter notes with `notes`."""
    if not notes:
        return
    notes_slide = slide.notes_slide  # creates one if absent
    notes_slide.notes_text_frame.text = notes


def _build_slide(prs: Presentation, layout: Any, spec: Slide) -> None:
    new = prs.slides.add_slide(layout)
    available = {ph.placeholder_format.idx: ph for ph in new.placeholders}
    for idx, value in spec.placeholders.items():
        ph = available.get(idx)
        if ph is None:
            log.warning(
                "layout '%s' has no placeholder idx=%d (available: %s)",
                layout.name,
                idx,
                sorted(available.keys()),
            )
            continue
        # Picture placeholders take a file path (str), all other
        # placeholders take text or a list of bullets.
        if (
            ph.placeholder_format.type == PP_PLACEHOLDER.PICTURE
            and isinstance(value, str)
        ):
            _set_picture(ph, value)
        else:
            _set_text(ph, value)
    _add_notes(new, spec.notes)


SCREENSHOTS_DIR = (
    Path(__file__).resolve().parent.parent
    / "docs" / "presentation" / "screenshots"
)


def _set_picture(placeholder: Any, image_path: str) -> None:
    """Insert an image into a PICTURE placeholder.

    python-pptx's ``placeholder.insert_picture()`` replaces the
    placeholder with a fitted picture shape, inheriting the
    placeholder's frame geometry from the template. We silently skip
    when the file does not exist - the caller is expected to have
    pre-validated existence via :func:`_apply_screenshots`, so a
    missing file here means a logic error worth logging.
    """
    p = Path(image_path).expanduser()
    if not p.exists():
        log.warning("picture placeholder pointed at missing file %s", p)
        return
    placeholder.insert_picture(str(p))


# ---------------------------------------------------------------------------
# Screenshot auto-wiring for the exec-topdown profile
# ---------------------------------------------------------------------------
#
# When a captured screenshot is available, swap the slide's layout to one
# of the picture-bearing layouts in the Splunk template and trim the
# bullets to fit the narrower text column. When the PNG is absent we
# keep the original text-only layout, so the deck always renders even
# before captures land.
#
# Mapping rules (per slide identity in EXEC_TOPDOWN_SLIDES):
#
#   slide title prefix              -> screenshot filename stem
#   "The platform under the lens"   -> slide-03-architecture
#   "0:02-0:07 ..."                 -> slide-05-overview-glass-table
#   "0:07-0:10 ..."                 -> slide-06-episode-review
#   "0:10-0:16 ..."                 -> slide-07-apm-service-map
#   "0:17-0:21 ..."                 -> slide-10-rum-overview
#   "0:21-0:25 ..."                 -> slide-11-glass-table-thousandeyes
#   "0:25-0:27 ..." (Quote slide)   -> slide-12-slo-burn
#
# The chosen photo layouts:
#
#   * "1/3 Slide Title, Section, Body, 2/3 Photo"
#       placeholders: 0=TITLE, 12=BODY(section), 13=BODY(bullets), 14=PICTURE
#       used for: timeline slides (5, 6, 7, 10, 11) - wide UI screenshots
#                 share the right 2/3, trimmed bullets on the left.
#   * "1/2 Slide Section, Title 1, Photo 1"
#       placeholders: 0=TITLE, 12=BODY, 13=PICTURE
#       used for: slide 3 (architecture diagram) and slide 12 (SLO
#                 burn quote with photo).

PHOTO_LAYOUT_BULLETS = "1/3 Slide Title, Section, Body, 2/3 Photo"
PHOTO_LAYOUT_HALF = "1/2 Slide Section, Title 1, Photo 1"

# Map "title startswith" -> (screenshot stem, trimmed bullets, layout)
SCREENSHOT_RULES: list[dict[str, Any]] = [
    {
        "title_prefix": "The platform under the lens",
        "stem": "slide-03-architecture",
        "layout": PHOTO_LAYOUT_HALF,
        "section": "Architecture",
        "bullets": [
            "24 microservices on EKS — polyglot, "
            "OpenTelemetry instrumented.",
            "Real Postgres / Redis / Kafka data plane.",
            "Six channels, six schemes.",
            "End-to-end Splunk + Cisco ThousandEyes.",
            "Live data, last 60 seconds, every panel.",
        ],
    },
    {
        "title_prefix": "0:02",
        "stem": "slide-05-overview-glass-table",
        "layout": PHOTO_LAYOUT_BULLETS,
        "section": "0:02 – 0:07",
        "bullets": [
            "Top KPI row — the COO numbers.",
            "L1 / L2 / Tier health rollup.",
            "Geography — by country and city.",
            "Decline rate by customer tier.",
            "Active incidents — SWIFT episode visible.",
        ],
    },
    {
        "title_prefix": "0:07",
        "stem": "slide-06-episode-review",
        "layout": PHOTO_LAYOUT_BULLETS,
        "section": "0:07 – 0:10",
        "bullets": [
            "One episode, one timeline.",
            "Correlation search owned by ops.",
            "Aggregation policy — 30 lines.",
            "Service Analyser for swift-network.",
            "Click-through to APM.",
        ],
    },
    {
        "title_prefix": "0:10",
        "stem": "slide-07-apm-service-map",
        "layout": PHOTO_LAYOUT_BULLETS,
        "section": "0:10 – 0:16",
        "bullets": [
            "Service map — 24 services, auto-drawn.",
            "Tag Spotlight on payment.scheme.",
            "Failing trace → waterfall.",
            "Logs in Context — one click.",
            "Root cause in one sentence.",
        ],
    },
    {
        "title_prefix": "0:17",
        "stem": "slide-10-rum-overview",
        "layout": PHOTO_LAYOUT_BULLETS,
        "section": "0:17 – 0:21",
        "bullets": [
            "RUM Overview — live sessions.",
            "Tag Spotlight by customer.tier.",
            "Bronze SPA failure-rate spike.",
            "Frustration Signals — rage-clicks.",
            "Journey replay, privacy-aware.",
        ],
    },
    {
        "title_prefix": "0:21",
        "stem": "slide-11-glass-table-thousandeyes",
        "layout": PHOTO_LAYOUT_BULLETS,
        "section": "0:21 – 0:25",
        "bullets": [
            "Madrid episode lights up.",
            "Network loss %, latency by agent.",
            "ThousandEyes in the same Glass Table.",
            "Cisco One — one pane, two stories.",
            "Per-city KPI: Madrid red, peers green.",
        ],
    },
    {
        # The original spec for this slide is a Quote layout where the
        # title placeholder holds the full closing quote. When we promote
        # it to a bullets+photo layout, that quote text would overflow
        # the title box, so we override it with a short descriptive
        # title and surface the quote inside the bullets block.
        "title_prefix": "0:25",
        "stem": "slide-12-slo-burn",
        "layout": PHOTO_LAYOUT_BULLETS,
        "section": "0:25 – 0:27",
        "title_override": "SLO burn + close",
        "bullets": [
            "SLO 1h fast-burn panel — error budget in real time.",
            "Active SLO breach episodes — auto-correlated to ITSI.",
            "The COO would have known.",
            "The SRE would have known the root cause in six minutes.",
            "The customer never had to call.",
        ],
    },
]


def _apply_screenshots(slides: list[Slide]) -> list[Slide]:
    """Return a copy of `slides` with photo-layout substitutions applied
    for any entry whose matching screenshot exists on disk. Slides
    without a captured screenshot are passed through unchanged."""
    out: list[Slide] = []
    applied = 0
    for spec in slides:
        title_val = spec.placeholders.get(0, "")
        title = title_val if isinstance(title_val, str) else " ".join(title_val)
        # Quote layouts store the visible timestamp in the section
        # placeholder (12), not the title (which holds the quote text).
        # Probe both so a screenshot rule still binds even when the slide
        # uses a quote layout.
        section_val = spec.placeholders.get(12, "")
        section = (
            section_val if isinstance(section_val, str) else " ".join(section_val)
        )
        rule = next(
            (
                r for r in SCREENSHOT_RULES
                if title.startswith(r["title_prefix"])
                or section.startswith(r["title_prefix"])
            ),
            None,
        )
        if rule is None:
            out.append(spec)
            continue
        png = SCREENSHOTS_DIR / f"{rule['stem']}.png"
        if not png.exists():
            out.append(spec)
            continue
        # When matching binds via the section placeholder (e.g., a Quote
        # layout whose title is the full quote text), fall back to the
        # rule's title_override. This prevents long quote sentences from
        # being squeezed into a single-line title box.
        rule_title = rule.get("title_override") or title
        if rule["layout"] == PHOTO_LAYOUT_BULLETS:
            new_placeholders: dict[int, Any] = {
                0: rule_title,
                12: rule["section"],
                13: rule["bullets"],
                14: str(png),
            }
        else:  # PHOTO_LAYOUT_HALF
            new_placeholders = {
                0: rule_title,
                12: rule["bullets"],
                13: str(png),
            }
        out.append(
            Slide(
                layout=rule["layout"],
                placeholders=new_placeholders,
                notes=spec.notes,
            )
        )
        applied += 1
        log.info(
            "screenshot: %s -> %s (%s)",
            rule["stem"], rule["layout"], png.name,
        )
    if applied == 0:
        log.info(
            "no screenshots found under %s; rendering text-only deck",
            SCREENSHOTS_DIR,
        )
    else:
        log.info("screenshot: applied %d slide(s)", applied)
    return out


def _spec_title_and_body(spec: Slide) -> tuple[str, list[str]]:
    """Best-effort extraction for fallback generation without template layouts."""
    title_val = spec.placeholders.get(0, "")
    title = title_val if isinstance(title_val, str) else " ".join(title_val)
    body: list[str] = []
    for idx, value in spec.placeholders.items():
        if idx == 0:
            continue
        if isinstance(value, str):
            body.append(value)
        else:
            body.extend(value)
    return title or "Slide", [line for line in body if line]


def _build_basic_deck(output: Path, slides: list[Slide]) -> None:
    """Generate a simple PPTX when the Splunk template is unavailable."""
    prs = Presentation()
    title_only_idx = 5 if len(prs.slide_layouts) > 5 else 0
    title_and_content_idx = 1 if len(prs.slide_layouts) > 1 else 0

    for spec in slides:
        title, body = _spec_title_and_body(spec)
        layout_idx = title_and_content_idx if body else title_only_idx
        slide = prs.slides.add_slide(prs.slide_layouts[layout_idx])

        if getattr(slide.shapes, "title", None) is not None:
            slide.shapes.title.text = title

        content_shape = None
        for ph in slide.placeholders:
            if not ph.has_text_frame:
                continue
            if slide.shapes.title is not None and ph == slide.shapes.title:
                continue
            content_shape = ph
            break

        if content_shape and body:
            tf = content_shape.text_frame
            tf.clear()
            tf.paragraphs[0].text = body[0]
            for line in body[1:]:
                p = tf.add_paragraph()
                p.text = line
                p.level = 0

        _add_notes(slide, spec.notes)

    output.parent.mkdir(parents=True, exist_ok=True)
    prs.save(str(output))
    size_kb = output.stat().st_size // 1024
    log.info(
        "wrote %s  (%d KB, %d slides, basic fallback)",
        output,
        size_kb,
        len(slides),
    )


def _log_layouts(prs: Presentation) -> None:
    """Diagnostic helper — prints all layouts and placeholder indices.
    Useful when we extend the deck and need to pick a new layout."""
    for master in prs.slide_masters:
        for layout in master.slide_layouts:
            phs = [
                f"{ph.placeholder_format.idx}:{ph.placeholder_format.type}"
                for ph in layout.placeholders
            ]
            log.info("  layout '%s'  ->  %s", layout.name, phs)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--template",
        default="/Users/mserieys/Documents/_Cursor/splunk-deck-2026.pptx",
        help="Splunk PowerPoint template (.pptx). Slide masters/layouts/"
             "fonts are inherited from this file.",
    )
    parser.add_argument(
        "--profile",
        choices=sorted(PROFILES.keys()),
        default="engineer",
        help=(
            "Which deck to render. 'engineer' (default) is the bottom-up "
            "Acts I+II cut aligned with docs/presentation/TALK_TRACK.md. "
            "'exec-topdown' is the 30-minute C-level cut aligned with "
            "docs/presentation/EXEC_DEMO_30MIN_TOPDOWN.md."
        ),
    )
    parser.add_argument(
        "--output",
        default=None,
        help=(
            "Destination .pptx file. Defaults to "
            "docs/presentation/slides.pptx for --profile engineer and "
            "docs/presentation/slides-exec-topdown.pptx for "
            "--profile exec-topdown."
        ),
    )
    parser.add_argument(
        "--list-layouts",
        action="store_true",
        help="Print every layout name and placeholder index in the "
             "template, then exit. Use this when extending the SLIDES "
             "list for a profile with a layout we haven't used before.",
    )
    parser.add_argument(
        "--fallback-basic",
        action="store_true",
        help=(
            "If --template is missing, generate a basic deck using the default "
            "python-pptx theme and a title+bullets heuristic."
        ),
    )
    args = parser.parse_args()

    slides = PROFILES[args.profile]
    if args.profile == "exec-topdown":
        slides = _apply_screenshots(slides)
    default_output = DEFAULT_OUTPUTS[args.profile]
    output = Path(args.output or default_output).expanduser()

    template = Path(args.template).expanduser()
    if not template.exists():
        if args.fallback_basic:
            log.warning("template not found: %s", template)
            log.warning("using fallback basic generation")
            _build_basic_deck(output, slides)
            return 0
        log.error("template not found: %s", template)
        return 2

    prs = Presentation(str(template))
    if args.list_layouts:
        _log_layouts(prs)
        return 0

    layouts = _layouts_by_name(prs)
    missing = [s.layout for s in slides if s.layout not in layouts]
    if missing:
        log.error(
            "the following layouts are not in the template:\n  %s\n"
            "Run with --list-layouts to see what is available.",
            "\n  ".join(sorted(set(missing))),
        )
        return 3

    log.info("template = %s", template)
    log.info("profile  = %s  (%d slides)", args.profile, len(slides))
    log.info("stripping %d existing slide(s) from template", len(prs.slides))
    _strip_existing_slides(prs)

    for i, spec in enumerate(slides, 1):
        log.info("[%2d/%d] %s", i, len(slides), spec.layout)
        _build_slide(prs, layouts[spec.layout], spec)

    output.parent.mkdir(parents=True, exist_ok=True)
    prs.save(str(output))
    size_kb = output.stat().st_size // 1024
    log.info("wrote %s  (%d KB, %d slides)", output, size_kb, len(slides))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
