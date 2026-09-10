"""Traffic generator for the NatWest Payments demo.

Drives the `api-gateway` service at a configurable rate with a realistic mix of
payment scenarios derived from the NatWest architecture diagram:

  - Faster Payments (real-time, low value, high volume)
  - CHAPS            (same-day high value)
  - Bacs             (batch)
  - SWIFT            (international)
  - SEPA             (European)
  - Cheque Image Clearing

Configuration via env vars:

  TARGET_URL        default: http://api-gateway.natwest.svc.cluster.local:8080/process
  RPS               default: 5  (constant fallback when RPS_SCHEDULE is empty)
  RPS_SCHEDULE      default: "" (JSON array of {hour, rps}; piecewise-linear)
  RPS_SCHEDULE_TZ   default: Europe/London
  DURATION_SECONDS  default: 0   (0 = run forever)
  ERROR_BURST_EVERY default: 120 (every N seconds, force an error burst)
  ERROR_BURST_SIZE  default: 20  (how many bad requests in a burst)
  TIER_MIX          default: "bronze:60,silver:30,gold:10"
                              Weighted persona pool. Each request picks one
                              persona at random per these weights so the
                              by-tier dashboards show a realistic majority
                              of Bronze users with a Gold tail. Format
                              matches helm tierBehaviour strings.
  AUTH_BEACON_URL   default: derived from TARGET_URL host -> /api/auth/event
                              The api-gateway exposes a beacon for SPA login
                              events that emits an `event_type=auth` audit
                              record into index=nwpay_audit. The traffic
                              generator hits this endpoint at AUTH_BEACON_RPS
                              with a realistic outcome mix so the L1 KPI
                              "Auth failure rate" lights up in ITSI without
                              requiring a human to log in via the SPA.
                              Set to "" to disable.
  AUTH_BEACON_RPS   default: 2  (auth events per second; integer)
  AUTH_OUTCOME_MIX  default: "success:95,failed:4,rate_limited:1"
                              Weighted outcome distribution -- mirrors the
                              TIER_MIX grammar. Outcomes outside the
                              {success,failed,rate_limited} allow-list are
                              dropped (audit.py also coerces server-side).

When RPS_SCHEDULE is set (e.g.
`[{"hour":9,"rps":40},{"hour":13,"rps":15},{"hour":17,"rps":35},{"hour":22,"rps":5}]`),
the generator linearly interpolates between adjacent points and wraps
back to the first point after 24h, giving realistic time-of-day shape so
the demo's RPS looks like a real bank's daily curve.
"""

from __future__ import annotations

import datetime as dt
import json
import logging
import os
import random
import sys
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

import requests
from requests.adapters import HTTPAdapter
from urllib.parse import urlparse

try:
    from zoneinfo import ZoneInfo
except ImportError:  # Python < 3.9 - we target 3.12 in the Dockerfile
    ZoneInfo = None  # type: ignore[assignment]


# ---------------------------------------------------------------------------
# OpenTelemetry RequestsInstrumentor: set peer.service on every outbound HTTP
# call.
#
# Without this hook, the splunk-opentelemetry distro auto-instruments
# `requests` but only emits `http.url` / `http.method` / `http.status_code`
# on the client span. Splunk APM's service map relies on the
# `peer.service` attribute to decide which downstream node to draw an
# edge to; with the attribute missing, traffic-generator's spans have
# nothing tying them to `api-gateway`, so APM renders traffic-generator
# as a disconnected island on the map (it emits spans but is never
# itself the target of an edge).
#
# Hook logic mirrors `app/service.py`: take the URL host's first DNS
# label as the peer name (`api-gateway` from
# `api-gateway.natwest.svc.cluster.local`). Failures are swallowed so a
# missing OTel SDK at import time never blocks the generator.
# ---------------------------------------------------------------------------
def _peer_service_request_hook(span, request_obj) -> None:
    if span is None or not span.is_recording():
        return
    try:
        url = getattr(request_obj, "url", None) or ""
        host = urlparse(url).hostname or ""
    except Exception:  # noqa: BLE001 - hook must never fail the request
        return
    if not host:
        return
    peer = host.split(".", 1)[0]
    if peer:
        span.set_attribute("peer.service", peer)


try:
    from opentelemetry.instrumentation.requests import RequestsInstrumentor

    _instrumentor = RequestsInstrumentor()
    if getattr(_instrumentor, "is_instrumented_by_opentelemetry", False):
        _instrumentor.uninstrument()
    _instrumentor.instrument(request_hook=_peer_service_request_hook)
except Exception:  # noqa: BLE001 - hook is best-effort, never block startup
    pass

# Manual tracer for the "submit_payment" span that wraps the simulated
# network RTT sleep + the actual HTTP POST. Splunk APM stitches this span
# in as the parent of the auto-instrumented requests CLIENT span, so a
# trace pivot from the api-gateway server span reveals the customer-side
# network latency contribution separately from gateway processing.
# Safe to fall back to None when OTel isn't available (e.g. unit tests):
# _send() guards on this.
try:
    from opentelemetry import trace as _otel_trace

    _tracer = _otel_trace.get_tracer("traffic-generator")
except Exception:  # noqa: BLE001 - manual tracing is best-effort
    _tracer = None  # type: ignore[assignment]

# Force unbuffered stdout so `kubectl logs -f` shows live stats lines even
# when the OTel Python distro wraps the root logger.
try:
    sys.stdout.reconfigure(line_buffering=True)
except (AttributeError, OSError):
    pass

TARGET_URL = os.environ.get(
    "TARGET_URL",
    "http://api-gateway.natwest.svc.cluster.local:8080/process",
)


def _derive_auth_beacon_url(target: str) -> str:
    """Derive the /api/auth/event URL from TARGET_URL.

    Splits on the last `/` to keep scheme://host:port intact, then appends
    the auth beacon path. Example:
      http://api-gateway:8080/process -> http://api-gateway:8080/api/auth/event
    """
    if not target:
        return ""
    base, _, _ = target.rpartition("/")
    if not base:
        return ""
    return f"{base}/api/auth/event"


AUTH_BEACON_URL = os.environ.get(
    "AUTH_BEACON_URL", _derive_auth_beacon_url(TARGET_URL)
).strip()
AUTH_BEACON_RPS = max(0, int(os.environ.get("AUTH_BEACON_RPS", "2")))
RPS = max(1, int(os.environ.get("RPS", "5")))
DURATION_SECONDS = int(os.environ.get("DURATION_SECONDS", "0"))
ERROR_BURST_EVERY = int(os.environ.get("ERROR_BURST_EVERY", "120"))
ERROR_BURST_SIZE = int(os.environ.get("ERROR_BURST_SIZE", "20"))
WORKERS = max(1, int(os.environ.get("WORKERS", "8")))
TIMEOUT_S = float(os.environ.get("TIMEOUT_S", "10"))
# urllib3 connection pool size per host. Default is 10, which strangles us
# at higher concurrency; size it to match WORKERS so each thread can hold
# its own connection without contending.
POOL_MAXSIZE = max(WORKERS * 2, 32)

RPS_SCHEDULE_TZ_NAME = os.environ.get("RPS_SCHEDULE_TZ", "Europe/London")
RPS_SCHEDULE_RAW = os.environ.get("RPS_SCHEDULE", "").strip()
# Optional separate curve for Saturday + Sunday. Same JSON grammar as
# RPS_SCHEDULE. Real UK retail-bank traffic on weekends is a flatter
# curve with a later peak (no 09:00 commuter spike, peak 14:00-18:00).
# Leave empty to use RPS_SCHEDULE for every day of the week.
RPS_SCHEDULE_WEEKEND_RAW = os.environ.get("RPS_SCHEDULE_WEEKEND", "").strip()


def _parse_schedule(raw: str) -> list[tuple[float, float]]:
    """Parse RPS_SCHEDULE into a sorted list of (hour, rps) tuples.

    Accepts a JSON array of objects with 'hour' (0..24, float) and 'rps'
    (>=1, float). Returns [] when raw is empty or invalid - the caller
    falls back to constant RPS.
    """
    if not raw:
        return []
    try:
        items = json.loads(raw)
    except json.JSONDecodeError:
        log.warning(json.dumps({"event": "schedule_parse_error", "raw": raw}))
        return []
    points: list[tuple[float, float]] = []
    for item in items:
        try:
            h = float(item["hour"])
            r = max(1.0, float(item["rps"]))
        except (KeyError, TypeError, ValueError):
            continue
        h = h % 24.0
        points.append((h, r))
    points.sort(key=lambda p: p[0])
    return points


def _is_weekend(now: dt.datetime) -> bool:
    """True when now falls on Saturday (5) or Sunday (6).

    Used both for the weekend RPS curve and for any future feature that
    needs to flag weekend vs weekday behaviour. Operates on whatever tz
    the caller hands us so the schedule respects RPS_SCHEDULE_TZ.
    """
    return now.weekday() >= 5


def _current_rps(
    points: list[tuple[float, float]],
    tz: object | None,
    weekend_points: list[tuple[float, float]] | None = None,
) -> float:
    """Linearly interpolate the schedule at the current local hour.

    When ``weekend_points`` is provided and we are currently on Sat/Sun,
    use that curve instead of ``points``. Wraps modulo 24h. With <2
    points the interpolation collapses to either the only known value or
    the constant RPS fallback.
    """
    now = dt.datetime.now(tz) if tz is not None else dt.datetime.now()
    if weekend_points and _is_weekend(now):
        points = weekend_points
    if not points:
        return float(RPS)
    if len(points) == 1:
        return points[0][1]
    h = now.hour + now.minute / 60.0 + now.second / 3600.0
    # Find the segment [a, b] that contains h, wrapping around.
    n = len(points)
    for i in range(n):
        a_h, a_r = points[i]
        b_h, b_r = points[(i + 1) % n]
        if i + 1 == n:
            b_h += 24.0
        if a_h <= h <= b_h:
            if b_h == a_h:
                return a_r
            t = (h - a_h) / (b_h - a_h)
            return a_r + t * (b_r - a_r)
    # h is before the first point; wrap from the last segment.
    a_h, a_r = points[-1]
    b_h, b_r = points[0]
    a_h -= 24.0
    if b_h == a_h:
        return b_r
    t = (h - a_h) / (b_h - a_h)
    return a_r + t * (b_r - a_r)

# Scenario mix weights roughly reflect real UK payment volumes.
#
# Amount ranges are *retail*-scale on purpose. Earlier versions used the
# regulatory scheme ceilings (CHAPS up to £10M, SWIFT up to £100M) which
# are correct for corporate-treasury flows but produce a per-payment mean
# of ~£3.4M across the mix - 200x higher than a real retail bank, and it
# blew up the "GBP at risk / minute" KPI on the Overview Glass Table to
# nonsensical £700M+ readings. The fixed ceilings below give a mean per
# payment of ~£15k, which matches Bank of England statistics for the
# subset of consumer-initiated payments NatWest's retail wing actually
# processes (FPS dominates volume, CHAPS / SWIFT are rare house-deposit
# and FX-remittance amounts respectively).
SCENARIOS: list[dict] = [
    {"name": "faster-payments", "scheme": "FPS",    "weight": 60, "min": 100,     "max": 25_000_00},
    {"name": "bacs",            "scheme": "BACS",   "weight": 15, "min": 100,     "max": 10_000_00},
    # CHAPS: retail high-value (house deposit, large transfer). Real-world
    # retail CHAPS averages ~£20-40k; corporate CHAPS can exceed £1M but
    # those aren't this demo's audience.
    {"name": "chaps",           "scheme": "CHAPS",  "weight":  8, "min": 1_000_00, "max": 50_000_00},
    {"name": "sepa",            "scheme": "SEPA",   "weight":  8, "min": 100,     "max": 50_000_00},
    # SWIFT: retail cross-border FX (overseas tuition, holiday-home
    # purchase, occasional remittance). Corporate SWIFT amounts are far
    # higher but distort the demo's KPIs.
    {"name": "swift",           "scheme": "SWIFT",  "weight":  6, "min": 100_00,  "max": 100_000_00},
    # Personal cheque: typical UK personal-cheque limit is £5,000 unless
    # the branch agrees a higher one; the £100k upper bound was
    # corporate-cheque territory.
    {"name": "cheque",          "scheme": "CHEQUE", "weight":  3, "min": 500,     "max": 5_000_00},
]

CHANNELS = [
    "mobile-app", "online-banking", "branch",
    "bankline", "bankline-direct", "partner-api",
]

# Per-region channel-mix weights. Lets every "channel by customer.location"
# panel tell a real story: Mediterranean markets are mobile-first (~60%
# mobile-app in ES/IT/PT), DACH skews to online-banking (~50% in DE), and
# British retail keeps a more even mobile/web split. The "EU-DEFAULT" row
# is the safety net for any region not listed (current LOCATIONS table
# only emits the three regions below, but future cities should not crash).
#
# Weights are *relative* - they only need to sum to a positive number;
# random.choices normalises internally.
REGION_CHANNEL_WEIGHTS: dict[str, dict[str, float]] = {
    "EU-WEST": {
        "mobile-app": 45, "online-banking": 35, "branch": 10,
        "bankline": 5, "bankline-direct": 3, "partner-api": 2,
    },
    "EU-CENTRAL": {
        "mobile-app": 30, "online-banking": 50, "branch": 12,
        "bankline": 4, "bankline-direct": 2, "partner-api": 2,
    },
    "EU-SOUTH": {
        "mobile-app": 60, "online-banking": 25, "branch": 10,
        "bankline": 3, "bankline-direct": 1, "partner-api": 1,
    },
    "EU-DEFAULT": {
        "mobile-app": 40, "online-banking": 35, "branch": 12,
        "bankline": 6, "bankline-direct": 4, "partner-api": 3,
    },
}


def _pick_channel(location: dict) -> str:
    """Return one channel using the region-biased weights above.

    Falls back to the uniform CHANNELS list if the region is unknown AND
    the EU-DEFAULT row is somehow missing - belt-and-braces guard so a
    typo in REGION_CHANNEL_WEIGHTS can never crash the request loop.
    """
    region = str(location.get("region") or "")
    weights = REGION_CHANNEL_WEIGHTS.get(region) or REGION_CHANNEL_WEIGHTS.get("EU-DEFAULT")
    if not weights:
        return random.choice(CHANNELS)
    pool = [(c, weights.get(c, 0.0)) for c in CHANNELS]
    total = sum(w for _, w in pool)
    if total <= 0:
        return random.choice(CHANNELS)
    return random.choices([c for c, _ in pool], weights=[w for _, w in pool], k=1)[0]

# Persona pool (mirrors frontend/src/personas.ts). Kept as a module-level
# constant so each request can pick a persona without re-allocating dicts.
# The id strings here MUST match those in personas.ts so APM and RUM agree
# on customer.id for the same human persona.
PERSONAS: list[dict[str, str]] = [
    {"id": "cust-uk-001", "name": "Olivia",   "tier": "bronze"},
    {"id": "cust-uk-002", "name": "James",    "tier": "silver"},
    {"id": "cust-uk-003", "name": "Margaret", "tier": "gold"},
]
KNOWN_TIERS = {"bronze", "silver", "gold"}


def _parse_tier_mix(raw: str) -> dict[str, float]:
    """Parse "bronze:60,silver:30,gold:10" into {tier: weight}.

    Same string layout as the helm tierBehaviour strings, so operators see
    a single consistent grammar. Bad entries are dropped silently; an empty
    or unparseable string yields the default 60/30/10 mix.
    """
    out: dict[str, float] = {}
    for entry in (raw or "").split(","):
        if ":" not in entry:
            continue
        tier, weight = entry.split(":", 1)
        tier = tier.strip().lower()
        if tier not in KNOWN_TIERS:
            continue
        try:
            w = max(0.0, float(weight))
        except ValueError:
            continue
        out[tier] = w
    if not out or sum(out.values()) <= 0:
        return {"bronze": 60.0, "silver": 30.0, "gold": 10.0}
    return out


TIER_MIX = _parse_tier_mix(os.environ.get("TIER_MIX", ""))


def _pick_persona() -> dict[str, str]:
    weights = [TIER_MIX.get(p["tier"], 0.0) for p in PERSONAS]
    if sum(weights) <= 0:
        # Defensive fallback - every persona equally likely. Should not happen
        # given _parse_tier_mix's guard, but keeps the request loop safe even
        # under a misconfigured TIER_MIX.
        return random.choice(PERSONAS)
    return random.choices(PERSONAS, weights=weights, k=1)[0]


# ---------------------------------------------------------------------------
# European customer locations. Each request picks a city from this weighted
# pool so the gateway and every downstream service can tag the resulting
# spans with customer.location / customer.country / customer.region.
#
# `rtt_mean_ms` / `rtt_stddev_ms` model the customer-to-gateway round-trip
# time as seen from each city. _send() sleeps for a gaussian sample of this
# distribution *before* the HTTP POST, so the "submit_payment" wrapper span
# carries a duration that includes the simulated network latency. Madrid
# is deliberately elevated (~9x London) so it stands out on every "p95 by
# customer.location" panel - the demo's "Spain looks slow" story.
# ---------------------------------------------------------------------------
LOCATIONS: list[dict] = [
    {"city": "london",    "country": "GB", "region": "EU-WEST",    "tz": "Europe/London",    "lat": 51.5074, "lon": -0.1278, "rtt_mean_ms":  50, "rtt_stddev_ms":  15, "weight": 40},
    {"city": "frankfurt", "country": "DE", "region": "EU-CENTRAL", "tz": "Europe/Berlin",    "lat": 50.1109, "lon":  8.6821, "rtt_mean_ms": 100, "rtt_stddev_ms":  25, "weight": 18},
    {"city": "paris",     "country": "FR", "region": "EU-WEST",    "tz": "Europe/Paris",     "lat": 48.8566, "lon":  2.3522, "rtt_mean_ms":  80, "rtt_stddev_ms":  20, "weight": 14},
    {"city": "madrid",    "country": "ES", "region": "EU-SOUTH",   "tz": "Europe/Madrid",    "lat": 40.4168, "lon": -3.7038, "rtt_mean_ms": 450, "rtt_stddev_ms": 120, "weight": 10},
    {"city": "milan",     "country": "IT", "region": "EU-SOUTH",   "tz": "Europe/Rome",      "lat": 45.4642, "lon":  9.1900, "rtt_mean_ms": 150, "rtt_stddev_ms":  35, "weight":  8},
    {"city": "amsterdam", "country": "NL", "region": "EU-WEST",    "tz": "Europe/Amsterdam", "lat": 52.3676, "lon":  4.9041, "rtt_mean_ms":  80, "rtt_stddev_ms":  20, "weight":  4},
    {"city": "dublin",    "country": "IE", "region": "EU-WEST",    "tz": "Europe/Dublin",    "lat": 53.3498, "lon": -6.2603, "rtt_mean_ms":  60, "rtt_stddev_ms":  15, "weight":  3},
    {"city": "lisbon",    "country": "PT", "region": "EU-SOUTH",   "tz": "Europe/Lisbon",    "lat": 38.7223, "lon": -9.1393, "rtt_mean_ms": 180, "rtt_stddev_ms":  40, "weight":  2},
    {"city": "brussels",  "country": "BE", "region": "EU-WEST",    "tz": "Europe/Brussels",  "lat": 50.8503, "lon":  4.3517, "rtt_mean_ms":  90, "rtt_stddev_ms":  20, "weight":  1},
]
KNOWN_CITIES = {loc["city"] for loc in LOCATIONS}
_LOCATION_INDEX: dict[str, dict] = {loc["city"]: loc for loc in LOCATIONS}


def _parse_location_mix(raw: str) -> dict[str, float]:
    """Parse "london:40,paris:14,madrid:10,..." into {city: weight}.

    Same grammar the existing TIER_MIX parser uses (split on "," then on
    ":") so operators see one consistent string layout. Unknown city
    names are dropped silently; an empty or unparseable string yields
    the default weights baked into the LOCATIONS table above.
    """
    out: dict[str, float] = {}
    for entry in (raw or "").split(","):
        if ":" not in entry:
            continue
        city, weight = entry.split(":", 1)
        city = city.strip().lower()
        if city not in KNOWN_CITIES:
            continue
        try:
            w = max(0.0, float(weight))
        except ValueError:
            continue
        out[city] = w
    if not out or sum(out.values()) <= 0:
        return {loc["city"]: float(loc["weight"]) for loc in LOCATIONS}
    return out


def _parse_location_latency_profiles(raw: str) -> dict[str, tuple[float, float]]:
    """Parse "london:50/15,madrid:450/120,..." into {city: (mean_ms, stddev_ms)}.

    Uses "/" inside each entry to separate mean from stddev so the outer
    "," separator stays consistent with TIER_MIX / LOCATION_MIX. Unknown
    cities or malformed pairs are dropped silently; missing cities
    inherit the LOCATIONS table baseline (rtt_mean_ms / rtt_stddev_ms).
    Use this to dial up Madrid's latency for a live demo without
    rebuilding the container, e.g.
    LOCATION_LATENCY_PROFILES="madrid:1500/300".
    """
    out: dict[str, tuple[float, float]] = {}
    for entry in (raw or "").split(","):
        if ":" not in entry:
            continue
        city, profile = entry.split(":", 1)
        city = city.strip().lower()
        if city not in KNOWN_CITIES:
            continue
        if "/" not in profile:
            continue
        mean_raw, stddev_raw = profile.split("/", 1)
        try:
            mean_ms = max(0.0, float(mean_raw))
            stddev_ms = max(0.0, float(stddev_raw))
        except ValueError:
            continue
        out[city] = (mean_ms, stddev_ms)
    return out


LOCATION_MIX = _parse_location_mix(os.environ.get("LOCATION_MIX", ""))
LOCATION_LATENCY_OVERRIDES = _parse_location_latency_profiles(
    os.environ.get("LOCATION_LATENCY_PROFILES", "")
)


def _pick_location() -> dict:
    holiday_countries = _todays_holiday_countries() if BANK_HOLIDAYS_ENABLED else set()
    weights: list[float] = []
    for loc in LOCATIONS:
        base = LOCATION_MIX.get(loc["city"], 0.0)
        if loc["country"] in holiday_countries:
            weights.append(0.0)
        else:
            weights.append(base)
    if sum(weights) <= 0:
        # Every city on holiday simultaneously (extremely unlikely with
        # 9 European countries; only possible on 01-01 / 12-25). Fall
        # back to the raw weights so traffic doesn't collapse to zero -
        # the holiday calendar is a realism garnish, not a hard switch.
        weights = [LOCATION_MIX.get(loc["city"], 0.0) for loc in LOCATIONS]
        if sum(weights) <= 0:
            return random.choice(LOCATIONS)
    return random.choices(LOCATIONS, weights=weights, k=1)[0]


# ---------------------------------------------------------------------------
# Bank-holiday calendar (2026). Per ISO-3166-1 alpha-2 country code, a list
# of MM-DD strings - the year is dropped so this table doesn't need
# regenerating every December. Real banks shift settlement to T+1 on
# domestic schemes during public holidays; we model the operator-visible
# side by zeroing out the affected city's weight in _pick_location(),
# so dashboards show "Spain went dark today" and the rest of Europe
# absorbs the load.
#
# Sourced from python-holidays 0.60 (2026 release). Re-run annually with:
#   import holidays
#   for cc in ["GB","DE","FR","ES","IT","NL","IE","PT","BE"]:
#       print(cc, sorted({d.strftime("%m-%d") for d in holidays.country_holidays(cc, years=2026)}))
# ---------------------------------------------------------------------------
BANK_HOLIDAYS_BY_COUNTRY: dict[str, list[str]] = {
    "GB": ["01-01", "04-03", "04-06", "05-04", "05-25", "08-31", "12-25", "12-28"],
    "DE": ["01-01", "04-03", "04-06", "05-01", "05-14", "05-25", "10-03", "12-25", "12-26"],
    "FR": ["01-01", "04-06", "05-01", "05-08", "05-14", "05-25", "07-14", "08-15", "11-01", "11-11", "12-25"],
    "ES": ["01-01", "01-06", "04-03", "05-01", "08-15", "10-12", "11-01", "12-06", "12-08", "12-25"],
    "IT": ["01-01", "01-06", "04-06", "04-25", "05-01", "06-02", "08-15", "11-01", "12-08", "12-25", "12-26"],
    "NL": ["01-01", "04-03", "04-06", "04-27", "05-05", "05-14", "05-25", "12-25", "12-26"],
    "IE": ["01-01", "02-02", "03-17", "04-06", "05-04", "06-01", "08-03", "10-26", "12-25", "12-28"],
    "PT": ["01-01", "04-03", "04-06", "04-25", "05-01", "06-04", "06-10", "08-15", "10-05", "11-01", "12-01", "12-08", "12-25"],
    "BE": ["01-01", "04-06", "05-01", "05-14", "05-25", "07-21", "08-15", "11-01", "11-11", "12-25"],
}


def _parse_bool_env(raw: str | None, default: bool) -> bool:
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on", "y"}


BANK_HOLIDAYS_ENABLED = _parse_bool_env(os.environ.get("BANK_HOLIDAYS_ENABLED"), True)
# Optional override: force a particular MM-DD to be "today" for the
# holiday calendar. Lets a presenter demo the "Spain is dark today" story
# on a regular Tuesday by setting BANK_HOLIDAY_DATE_OVERRIDE="10-12"
# (Hispanidad). Empty string => use the real current date.
BANK_HOLIDAY_DATE_OVERRIDE = (os.environ.get("BANK_HOLIDAY_DATE_OVERRIDE", "") or "").strip()


def _todays_holiday_countries() -> set[str]:
    """Return the set of ISO country codes whose calendar lists today.

    Reads BANK_HOLIDAY_DATE_OVERRIDE first so presenters can simulate
    any date; otherwise uses the system's UTC date (we don't care about
    sub-day tz drift - settlement closes for the whole day either way).
    Malformed overrides fall back to the real date.
    """
    override = BANK_HOLIDAY_DATE_OVERRIDE
    if override and len(override) == 5 and override[2] == "-":
        today = override
    else:
        today = dt.datetime.now(dt.timezone.utc).strftime("%m-%d")
    return {
        country
        for country, dates in BANK_HOLIDAYS_BY_COUNTRY.items()
        if today in dates
    }


# ---------------------------------------------------------------------------
# Roaming model. By default the persona's "home country" (where their bank
# account lives) equals the city they're paying from - i.e. the customer
# is at home. With ROAMING_RATE probability (default 5%) we override the
# home_country to a DIFFERENT country drawn from the LOCATIONS pool, so
# the resulting payment looks like a real "I'm in Madrid for a long
# weekend but my account is in London" event. We tag both the span and
# the audit payload with `payment.roaming=true` so the fraud-detection
# story has a stable ~5% baseline of cross-border activity to pivot on -
# and so a chaos scenario can later spike this rate to simulate a fraud
# incident.
#
# Important: we deliberately do NOT change `originator_country` here.
# The location-pool weights (LOCATION_MIX) remain the only lever for
# volume curves, and `customer.country` still reflects where the request
# actually came from. The new `customer.home_country` is the orthogonal
# fraud-signal field.
# ---------------------------------------------------------------------------
def _parse_roaming_rate(raw: str) -> float:
    try:
        v = float(raw)
    except (TypeError, ValueError):
        return 0.05
    return max(0.0, min(1.0, v))


ROAMING_RATE = _parse_roaming_rate(os.environ.get("ROAMING_RATE", "0.05"))
_ALL_LOCATION_COUNTRIES: list[str] = sorted({loc["country"] for loc in LOCATIONS})


def _resolve_home_country(location: dict) -> tuple[str, bool]:
    """Return (home_country, is_roaming).

    Most calls return (location.country, False) - the customer is at home.
    With ROAMING_RATE probability we pick a DIFFERENT country uniformly
    from the LOCATIONS pool and return (that, True) - the customer is
    traveling. If no other country exists in the pool we degrade
    gracefully to the not-roaming branch.
    """
    loc_country = str(location.get("country") or "")
    if ROAMING_RATE <= 0.0 or random.random() >= ROAMING_RATE:
        return loc_country, False
    candidates = [c for c in _ALL_LOCATION_COUNTRIES if c != loc_country]
    if not candidates:
        return loc_country, False
    return random.choice(candidates), True


def _sample_rtt_ms(location: dict) -> float:
    """Return a non-negative gaussian sample of the city's network RTT.

    Mean/stddev come from LOCATION_LATENCY_OVERRIDES when set, otherwise
    from the LOCATIONS table baseline. Clamped at 0 so any unlucky negative
    gaussian tail doesn't yield a negative sleep.
    """
    override = LOCATION_LATENCY_OVERRIDES.get(location["city"])
    if override is not None:
        mean_ms, stddev_ms = override
    else:
        mean_ms = float(location["rtt_mean_ms"])
        stddev_ms = float(location["rtt_stddev_ms"])
    return max(0.0, random.gauss(mean_ms, stddev_ms))


# ---------------------------------------------------------------------------
# SPA auth beacon synthesis. The api-gateway exposes /api/auth/event for
# the SPA login flow; emit_auth_event() in app/audit.py turns each POST
# into one nwpay:auth record in index=nwpay_audit. Synthesising a steady
# stream of these from the traffic generator drives the ITSI KPI
# "Auth failure rate" without requiring a human to log into the SPA.
#
# Outcome enum is the closed set audit._KNOWN_AUTH_OUTCOMES; anything
# else gets coerced to "failed" server-side. We restrict the synthesised
# mix to the three outcomes that a real banking ops dashboard cares
# about (success, failed, rate_limited) so the failure-rate KPI yields
# a stable, realistic value (~4-5%).
# ---------------------------------------------------------------------------
_KNOWN_AUTH_OUTCOMES_TG = frozenset({"success", "failed", "rate_limited"})

AUTH_OUTCOME_MIX_RAW = os.environ.get(
    "AUTH_OUTCOME_MIX", "success:95,failed:4,rate_limited:1"
)


def _parse_outcome_mix(raw: str) -> dict[str, float]:
    """Parse "success:95,failed:4,rate_limited:1" into {outcome: weight}.

    Mirrors _parse_tier_mix grammar so operators see one consistent string
    layout across the helm values. Outcomes outside the allow-list are
    silently dropped; an empty / unparseable string yields the documented
    default 95/4/1 mix.
    """
    out: dict[str, float] = {}
    for entry in (raw or "").split(","):
        if ":" not in entry:
            continue
        name, weight = entry.split(":", 1)
        name = name.strip().lower()
        if name not in _KNOWN_AUTH_OUTCOMES_TG:
            continue
        try:
            w = max(0.0, float(weight))
        except ValueError:
            continue
        out[name] = w
    if not out or sum(out.values()) <= 0:
        return {"success": 95.0, "failed": 4.0, "rate_limited": 1.0}
    return out


AUTH_OUTCOME_MIX = _parse_outcome_mix(AUTH_OUTCOME_MIX_RAW)
_AUTH_OUTCOMES = list(AUTH_OUTCOME_MIX.keys())
_AUTH_WEIGHTS = [AUTH_OUTCOME_MIX[o] for o in _AUTH_OUTCOMES]
# 4-byte demo-grade synthetic IPv4 used in the audit payload's X-Forwarded-For
# so emit_auth_event records a plausible client_ip without exposing the
# pod IP. Deterministic per persona last-byte distribution drives the SCA
# outcome variability inside the api-gateway service handler.
_AUTH_USERNAMES = [p["name"].lower() for p in PERSONAS] + ["admin"]


def _pick_auth_outcome() -> str:
    return random.choices(_AUTH_OUTCOMES, weights=_AUTH_WEIGHTS, k=1)[0]

# Beneficiary country distribution per scheme. Drives `payment.country_pair`.
# Originator is now parameterised by the customer's location (see
# _country_pair) so the demo tells a multi-country story instead of the
# old "everyone is in GB" shape.
SWIFT_COUNTRIES   = ["US", "JP", "SG", "HK", "AE", "CH", "AU", "CA", "ZA"]
SEPA_COUNTRIES    = ["DE", "FR", "ES", "IT", "NL", "IE", "PT", "BE"]


def _bucket_amount(minor_units: int) -> str:
    """Return a human-friendly amount band for Tag Spotlight pivots.

    `minor_units` is GBP pence (or scheme-equivalent minor units). Bands chosen
    to roughly match how a payments-ops team segments transactions.
    """
    if minor_units < 100_000:           # < £1,000
        return "lt-1k"
    if minor_units < 1_000_000:         # < £10,000
        return "1k-10k"
    if minor_units < 10_000_000:        # < £100,000
        return "10k-100k"
    if minor_units < 100_000_000:       # < £1,000,000
        return "100k-1m"
    return "gt-1m"


def _country_pair(scheme: str, originator: str = "GB") -> tuple[str, str]:
    """Return (originator_country, beneficiary_country) for a scheme.

    Originator defaults to "GB" so any legacy caller that doesn't pass a
    location still gets the historical shape. With location-aware traffic
    enabled, _build_payload passes the customer's country so cross-border
    SEPA / SWIFT pairs reflect the realistic European retail flow, and
    domestic schemes (FPS / BACS / CHAPS / cheque) stay onshore.
    """
    if scheme == "SWIFT":
        return (originator, random.choice(SWIFT_COUNTRIES))
    if scheme == "SEPA":
        candidates = [c for c in SEPA_COUNTRIES if c != originator]
        return (originator, random.choice(candidates or SEPA_COUNTRIES))
    return (originator, originator)

logging.basicConfig(
    level=logging.INFO,
    stream=sys.stdout,
    format='{"ts":"%(asctime)s","level":"%(levelname)s","msg":%(message)s}',
)
log = logging.getLogger("traffic-generator")

_session = requests.Session()
# Wide connection pool - one HTTPAdapter shared by all worker threads.
_adapter = HTTPAdapter(pool_connections=POOL_MAXSIZE, pool_maxsize=POOL_MAXSIZE, max_retries=0)
_session.mount("http://", _adapter)
_session.mount("https://", _adapter)
_stop = threading.Event()
_total = 0
_errors = 0
_lock = threading.Lock()


def _pick_scenario() -> dict:
    weights = [s["weight"] for s in SCENARIOS]
    return random.choices(SCENARIOS, weights=weights, k=1)[0]


def _build_payload(force_bad: bool = False) -> dict:
    scenario = _pick_scenario()
    amount = random.randint(scenario["min"], scenario["max"])
    scheme = scenario["scheme"]
    persona = _pick_persona()
    location = _pick_location()
    home_country, is_roaming = _resolve_home_country(location)
    orig_country, bene_country = _country_pair(scheme, originator=location["country"])
    if scheme == "SWIFT":
        currency = random.choice(["USD", "EUR", "JPY", "GBP"])
    elif scheme == "SEPA":
        currency = "EUR"
    else:
        currency = "GBP"
    # Sample the simulated network RTT now (rather than inside _send) so
    # both the payload and the wrapper span agree on the exact value -
    # avoids two different gaussian draws diverging by tens of ms.
    sim_rtt_ms = _sample_rtt_ms(location)
    payload = {
        "payment_id": str(uuid.uuid4()),
        "scenario": scenario["name"],
        "scheme": scheme,
        "amount_minor_units": amount,
        "amount_bucket": _bucket_amount(amount),
        "currency": currency,
        "channel": _pick_channel(location),
        "originator_country": orig_country,
        "beneficiary_country": bene_country,
        "country_pair": f"{orig_country}-{bene_country}",
        "originator_sort_code": f"{random.randint(10,99)}-{random.randint(10,99)}-{random.randint(10,99)}",
        "beneficiary_sort_code": f"{random.randint(10,99)}-{random.randint(10,99)}-{random.randint(10,99)}",
        "customer_id": persona["id"],
        "customer_tier": persona["tier"],
        "customer_location": location["city"],
        "customer_country": location["country"],
        "customer_region": location["region"],
        "customer_lat": location["lat"],
        "customer_lon": location["lon"],
        "customer_home_country": home_country,
        "payment_roaming": is_roaming,
        # Round to one decimal place for tidy dashboards; the dial-by-ms
        # precision is in the wrapper span attribute, not the payload.
        "network_latency_ms_simulated": round(sim_rtt_ms, 1),
    }
    if force_bad:
        # A payload the downstream chain will treat like normal but tag as a burst
        payload["scenario"] = f"{scenario['name']}-burst"
        payload["force_error"] = True
    return payload


def _post_request(payload: dict) -> None:
    """Execute the HTTP POST and update the global counters.

    Split out from _send() so the wrapper-span and no-tracer paths share
    one implementation.
    """
    global _total, _errors
    try:
        resp = _session.post(TARGET_URL, json=payload, timeout=TIMEOUT_S)
        ok = 200 <= resp.status_code < 500
        with _lock:
            _total += 1
            if not ok:
                _errors += 1
    except requests.RequestException:
        with _lock:
            _total += 1
            _errors += 1


def _send(payload: dict) -> None:
    """Sleep for the simulated network RTT, then POST the payment.

    The sleep models the customer-to-gateway round trip from their city
    (London 50 ms, Madrid 450 ms, ...). Wrapping the sleep + POST in a
    manual "submit_payment" span gives Splunk APM a parent span whose
    duration includes the simulated network latency separately from the
    auto-instrumented requests CLIENT span (which captures only the
    server-side processing). The same hierarchy is what real RUM-to-APM
    pivots show: page event -> fetch span -> gateway server span.
    """
    sim_ms = float(payload.get("network_latency_ms_simulated") or 0.0)

    if _tracer is None:
        # No OTel SDK available (unit tests, distro disabled). Still
        # sleep for the RTT so the customer-facing latency story is
        # produced even when no spans are recorded.
        if sim_ms > 0.0:
            time.sleep(sim_ms / 1000.0)
        _post_request(payload)
        return

    with _tracer.start_as_current_span("submit_payment") as span:
        if span.is_recording():
            span.set_attribute("customer.location", str(payload.get("customer_location") or ""))
            span.set_attribute("customer.country", str(payload.get("customer_country") or ""))
            span.set_attribute("customer.region", str(payload.get("customer_region") or ""))
            span.set_attribute("customer.tier", str(payload.get("customer_tier") or ""))
            home_country = payload.get("customer_home_country")
            if home_country:
                span.set_attribute("customer.home_country", str(home_country))
            span.set_attribute("payment.roaming", bool(payload.get("payment_roaming") or False))
            cust_id = payload.get("customer_id")
            if cust_id:
                span.set_attribute("customer.id", str(cust_id))
            scheme = payload.get("scheme")
            if scheme:
                span.set_attribute("payment.scheme", str(scheme))
            span.set_attribute("network.latency_ms_simulated", sim_ms)
            # peer.service makes Splunk APM merge this client-side wrapper
            # with the api-gateway server span on the service map (otherwise
            # APM would render traffic-generator as a disconnected island).
            span.set_attribute("peer.service", "api-gateway")
        if sim_ms > 0.0:
            time.sleep(sim_ms / 1000.0)
        _post_request(payload)


_auth_total = 0
_auth_errors = 0


def _send_auth_beacon() -> None:
    """POST one synthetic SPA login event to /api/auth/event.

    Failure of the beacon itself is a generator-side error (counted in
    _auth_errors) -- it does NOT artificially inflate the
    "Auth failure rate" KPI, which counts records with outcome=failed
    inside the audit log, not HTTP failures.
    """
    global _auth_total, _auth_errors
    if not AUTH_BEACON_URL:
        return
    username = random.choice(_AUTH_USERNAMES)
    outcome = _pick_auth_outcome()
    # MFA flag uses persona-stable distribution: gold tier always uses MFA,
    # silver 70%, bronze 25%. Emit_auth_event coerces to bool server-side.
    persona = next((p for p in PERSONAS if p["name"].lower() == username), None)
    if persona is None:
        mfa = random.random() < 0.4
    else:
        mfa_rates = {"bronze": 0.25, "silver": 0.70, "gold": 1.0}
        mfa = random.random() < mfa_rates.get(persona["tier"], 0.4)
    # Synthesise a realistic public-internet IPv4 for X-Forwarded-For.
    # Deliberately scoped to 203.0.113.0/24 (TEST-NET-3, RFC 5737) so any
    # downstream alerting cannot be confused with a real customer source.
    xff = f"203.0.113.{random.randint(1, 254)}"
    payload = {"username": username, "outcome": outcome, "mfa": mfa}
    headers = {"X-Forwarded-For": xff}
    try:
        resp = _session.post(
            AUTH_BEACON_URL,
            json=payload,
            headers=headers,
            timeout=TIMEOUT_S,
        )
        ok = 200 <= resp.status_code < 500
        with _lock:
            _auth_total += 1
            if not ok:
                _auth_errors += 1
    except requests.RequestException:
        with _lock:
            _auth_total += 1
            _auth_errors += 1


def _auth_beacon_loop(pool: ThreadPoolExecutor) -> None:
    """Submit synthetic auth beacons at a steady AUTH_BEACON_RPS.

    Independent of the payment loop (so a payment burst does not steal
    auth slots and vice versa). Sleeps between submissions; uses the
    same shared ThreadPoolExecutor to avoid creating a second worker
    pool. Does nothing when AUTH_BEACON_URL is empty or RPS <= 0.
    """
    if not AUTH_BEACON_URL or AUTH_BEACON_RPS <= 0:
        log.info(json.dumps({"event": "auth_beacon_disabled"}))
        return
    interval = 1.0 / float(AUTH_BEACON_RPS)
    next_send = time.monotonic()
    while not _stop.is_set():
        now = time.monotonic()
        if now < next_send:
            time.sleep(min(0.5, next_send - now))
            continue
        pool.submit(_send_auth_beacon)
        next_send += interval


def _burst_trigger(pool: ThreadPoolExecutor) -> None:
    """Periodically submit a burst of bursty-tagged requests."""
    if ERROR_BURST_EVERY <= 0:
        return
    next_burst = time.monotonic() + ERROR_BURST_EVERY
    while not _stop.is_set():
        time.sleep(1)
        if time.monotonic() >= next_burst:
            log.info(json.dumps({"event": "error_burst", "size": ERROR_BURST_SIZE}))
            for _ in range(ERROR_BURST_SIZE):
                pool.submit(_send, _build_payload(force_bad=True))
            next_burst = time.monotonic() + ERROR_BURST_EVERY


def _stats_printer() -> None:
    last_total = 0
    last_auth_total = 0
    while not _stop.is_set():
        time.sleep(10)
        with _lock:
            t, e = _total, _errors
            at, ae = _auth_total, _auth_errors
        delta = t - last_total
        auth_delta = at - last_auth_total
        last_total = t
        last_auth_total = at
        # Use print() directly: the OTel Python distro hijacks `logging.*`
        # and routes log records to OTLP, which means `log.info(...)` does
        # not show up in `kubectl logs`. We want the stats line in stdout
        # for live RPS visibility, while still letting the logger capture
        # everything else (request/error events) for Splunk.
        print(json.dumps({
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "level": "INFO",
            "msg": {
                "event": "stats",
                "total": t,
                "errors": e,
                "rps_last_10s": delta / 10.0,
                "auth_total": at,
                "auth_errors": ae,
                "auth_rps_last_10s": auth_delta / 10.0,
            },
        }), flush=True)


def main() -> int:
    schedule_points = _parse_schedule(RPS_SCHEDULE_RAW)
    weekend_points = _parse_schedule(RPS_SCHEDULE_WEEKEND_RAW)
    tz: object | None = None
    if (schedule_points or weekend_points) and ZoneInfo is not None:
        try:
            tz = ZoneInfo(RPS_SCHEDULE_TZ_NAME)
        except Exception:  # noqa: BLE001 - fall back to UTC if tz unknown
            tz = None

    log.info(json.dumps({
        "event": "start",
        "target": TARGET_URL,
        "rps": RPS,
        "rps_schedule": schedule_points,
        "rps_schedule_weekend": weekend_points,
        "rps_schedule_tz": RPS_SCHEDULE_TZ_NAME if (schedule_points or weekend_points) else None,
        "duration_seconds": DURATION_SECONDS,
        "tier_mix": TIER_MIX,
        "location_mix": LOCATION_MIX,
        "location_latency_overrides": {
            city: {"mean_ms": mean, "stddev_ms": stddev}
            for city, (mean, stddev) in LOCATION_LATENCY_OVERRIDES.items()
        },
        "roaming_rate": ROAMING_RATE,
        "bank_holidays_enabled": BANK_HOLIDAYS_ENABLED,
        "bank_holiday_date_override": BANK_HOLIDAY_DATE_OVERRIDE,
        "bank_holiday_countries_today": (
            sorted(_todays_holiday_countries()) if BANK_HOLIDAYS_ENABLED else []
        ),
        "auth_beacon_url": AUTH_BEACON_URL,
        "auth_beacon_rps": AUTH_BEACON_RPS,
        "auth_outcome_mix": AUTH_OUTCOME_MIX,
    }))

    pool = ThreadPoolExecutor(max_workers=WORKERS)
    threading.Thread(target=_stats_printer, daemon=True).start()
    threading.Thread(target=_burst_trigger, args=(pool,), daemon=True).start()
    threading.Thread(target=_auth_beacon_loop, args=(pool,), daemon=True).start()

    start = time.monotonic()
    next_send = time.monotonic()
    last_rps_log = 0.0
    try:
        while not _stop.is_set():
            if DURATION_SECONDS and (time.monotonic() - start) > DURATION_SECONDS:
                break
            current_rps = _current_rps(schedule_points, tz, weekend_points)
            interval = 1.0 / max(1.0, current_rps)
            now = time.monotonic()
            if now < next_send:
                time.sleep(max(0, next_send - now))
            pool.submit(_send, _build_payload())
            next_send += interval

            # Periodic schedule heartbeat (every 60s) so operators can see
            # the RPS curve evolving in `kubectl logs`.
            if schedule_points and (now - last_rps_log) > 60.0:
                print(json.dumps({
                    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "level": "INFO",
                    "msg": {"event": "rps_target", "rps": round(current_rps, 2)},
                }), flush=True)
                last_rps_log = now
    except KeyboardInterrupt:
        log.info(json.dumps({"event": "interrupt"}))
    finally:
        _stop.set()
        pool.shutdown(wait=True)

    log.info(json.dumps({"event": "stop", "total": _total, "errors": _errors}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
