"""NatWest Payments demo - template microservice.

One binary, reused as every service in the topology. Behaviour is driven entirely
by environment variables:

  OTEL_SERVICE_NAME     - logical service name (e.g. payment-initiation-service)
  DOWNSTREAMS           - comma-separated list of downstream service DNS names
  DOWNSTREAM_FANOUT     - "all" (default) or "random:<n>" to call n random downstreams
  ERROR_RATE            - probability [0,1] of returning 5xx, default 0.01
  LATENCY_MS_MEAN       - mean simulated local work latency in ms, default 30
  LATENCY_MS_STDDEV     - stddev of simulated latency in ms, default 10
  SERVICE_TIER          - free-text tag (experience/payment/business/ledger/network)

Optional features (all disabled by default; switched on per-service via Helm):

  CACHE_ENABLED         - "true"|"false" - enable Redis cache lookup before work
  CACHE_URL             - redis://<host>:<port>/<db>
  CACHE_HIT_RATE        - probability [0,1] of a cache "hit" (skips tail latency)
  CACHE_KEY_NAMESPACE   - logical cache namespace (e.g. "sanctions" or "fraud_features")

  KAFKA_PRODUCER_ENABLED  - "true"|"false" - publish to Kafka after success
  KAFKA_CONSUMER_ENABLED  - "true"|"false" - run a background Kafka consumer loop
  KAFKA_BOOTSTRAP_SERVERS - host:port (e.g. "kafka:9092")
  KAFKA_TOPIC             - topic name (e.g. "payments.settled")
  KAFKA_CONSUMER_GROUP    - consumer group id (defaults to OTEL_SERVICE_NAME)

No real payment logic is executed; the purpose is to produce realistic OpenTelemetry
traces, metrics and logs through the Splunk OTel Collector for Splunk Observability.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import logging
import os
import random
import sys
import threading
import time
import uuid
from collections import deque
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any, Deque
from urllib.parse import urlparse

import requests
import requests.adapters
from flask import Flask, jsonify, request
from opentelemetry import context as otel_context
from opentelemetry import propagate, trace
from opentelemetry.trace import SpanKind, Status, StatusCode


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        return float(raw)
    except ValueError:
        return default


def _env_bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name, "")
    if raw == "":
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _env_list(name: str) -> list[str]:
    raw = os.environ.get(name, "")
    return [item.strip() for item in raw.split(",") if item.strip()]


SERVICE_NAME = os.environ.get("OTEL_SERVICE_NAME", "unknown-service")
SERVICE_TIER = os.environ.get("SERVICE_TIER", "unknown")
DOWNSTREAMS = _env_list("DOWNSTREAMS")
DOWNSTREAM_FANOUT = os.environ.get("DOWNSTREAM_FANOUT", "all")
ERROR_RATE = max(0.0, min(1.0, _env_float("ERROR_RATE", 0.01)))
LATENCY_MEAN = max(0.0, _env_float("LATENCY_MS_MEAN", 30.0))
LATENCY_STD = max(0.0, _env_float("LATENCY_MS_STDDEV", 10.0))

# Tail-latency injection (the "long-tail" / sticky-DB-lock story).
TAIL_LATENCY_RATE = max(0.0, min(1.0, _env_float("TAIL_LATENCY_RATE", 0.0)))
TAIL_LATENCY_MIN_MS = max(0.0, _env_float("TAIL_LATENCY_MIN_MS", 1500.0))
TAIL_LATENCY_MAX_MS = max(TAIL_LATENCY_MIN_MS, _env_float("TAIL_LATENCY_MAX_MS", 4500.0))

# Optional per-scheme error multiplier. Format: "FPS:1,CHAPS:1,SWIFT:3,SEPA:1,BACS:1,CHEQUE:1"
SCHEME_ERROR_MULTIPLIERS: dict[str, float] = {}
_raw_scheme_mult = os.environ.get("SCHEME_ERROR_MULTIPLIERS", "")
for _entry in _raw_scheme_mult.split(","):
    if ":" in _entry:
        _k, _v = _entry.split(":", 1)
        try:
            SCHEME_ERROR_MULTIPLIERS[_k.strip().upper()] = max(0.0, float(_v))
        except ValueError:
            pass

# --- Location-conditional degradation ("Spain link / ES screening provider is
# degraded" story). Default OFF (empty country) so EVERY service behaves
# identically until a chaos scenario arms it on ONE service (typically
# sanctions-aml-service). When an incoming payment's customer_country matches
# SLOW_LOCATION_COUNTRY we (a) sleep an extra SLOW_LOCATION_LATENCY_MS (+/-
# jitter) so the payment is slow, and (b) with probability
# SLOW_LOCATION_ERROR_RATE record a descriptive exception + structured log and
# return 5xx so the APM trace shows a clear root cause ("why"). Scoped by
# country, so only the targeted region is affected - all other personas and
# synthetic cities are untouched. Deliberately keyed off customer_country
# (NOT span duration / DB latency), so it is provably independent of the
# db-slow scenario and never perturbs the ledger/postgres rollup.
SLOW_LOCATION_COUNTRY = os.environ.get("SLOW_LOCATION_COUNTRY", "").strip().upper()
SLOW_LOCATION_LATENCY_MS = max(0.0, _env_float("SLOW_LOCATION_LATENCY_MS", 0.0))
SLOW_LOCATION_JITTER_MS = max(0.0, _env_float("SLOW_LOCATION_JITTER_MS", 0.0))
SLOW_LOCATION_ERROR_RATE = max(0.0, min(1.0, _env_float("SLOW_LOCATION_ERROR_RATE", 0.0)))
SLOW_LOCATION_DEPENDENCY = os.environ.get(
    "SLOW_LOCATION_DEPENDENCY", "aml-screening-provider-eu-south"
).strip()


def _parse_tier_prob_map(env_name: str) -> dict[str, float]:
    """Parse "bronze:0.0,silver:0.2,gold:0.6" into a {tier: prob} dict.

    Same string layout the existing SCHEME_ERROR_MULTIPLIERS uses, lower-cased.
    Bad entries are silently dropped so a typo in Helm doesn't break the pod.
    """
    out: dict[str, float] = {}
    for entry in os.environ.get(env_name, "").split(","):
        if ":" not in entry:
            continue
        key, value = entry.split(":", 1)
        try:
            out[key.strip().lower()] = max(0.0, min(1.0, float(value)))
        except ValueError:
            continue
    return out


# Tier-aware behaviour knobs. Set globally in helm/natwest-payments/values.yaml
# under `tierBehaviour:` and plumbed via deployment.yaml. Empty string => no
# tier behaviour applied (legacy behaviour, identical to pre-tier code path).
#
#   TIER_THROTTLE_PROB        - probability per tier that api-gateway returns
#                               HTTP 429 instead of fanning out. Only honoured
#                               when SERVICE_TIER == "gateway" so deeper
#                               services in the chain don't multiplicatively
#                               throttle the same Bronze request.
#   TIER_FRAUD_FAST_PATH_PROB - probability per tier that fraud-detection
#                               service skips the heavy fingerprint kernel
#                               and the tail-latency code path. Only honoured
#                               when FRAUD_FEATURE_EXTRACTOR_ENABLED is true,
#                               which scopes it to fraud-detection-service.
TIER_THROTTLE_PROB = _parse_tier_prob_map("TIER_THROTTLE_PROB")
TIER_FRAUD_FAST_PATH_PROB = _parse_tier_prob_map("TIER_FRAUD_FAST_PATH_PROB")
KNOWN_TIERS = frozenset({"bronze", "silver", "gold"})

DOWNSTREAM_PORT = int(os.environ.get("DOWNSTREAM_PORT", "8080"))
DOWNSTREAM_TIMEOUT_S = _env_float("DOWNSTREAM_TIMEOUT_S", 2.0)
DOWNSTREAM_SCHEME = "http"

MAX_FANOUT_WORKERS = max(1, min(16, len(DOWNSTREAMS) or 1))

# --- Redis cache config ----------------------------------------------------
CACHE_ENABLED = _env_bool("CACHE_ENABLED", False)
CACHE_URL = os.environ.get("CACHE_URL", "")
CACHE_HIT_RATE = max(0.0, min(1.0, _env_float("CACHE_HIT_RATE", 0.0)))
CACHE_KEY_NAMESPACE = os.environ.get("CACHE_KEY_NAMESPACE", "default")

# --- Fraud feature extractor (CPU regression demo) -------------------------
# Enabled only on fraud-detection-service via Helm. When on, every /process
# call runs a fingerprinting kernel inside a named child span - this gives
# AlwaysOn Profiling a stable CPU baseline to diff against.
#
#   FRAUD_FEATURE_EXTRACTOR_ENABLED  - "true"|"false" - turn the kernel on
#   FRAUD_FEATURE_COUNT              - int, vector size N (default 96)
#   CPU_REGRESSION_ENABLED           - "true"|"false" - swap the linear
#                                      O(N) fingerprint for a deliberately
#                                      quadratic O(N^2) pairwise kernel.
#                                      Same external behaviour, ~30-60x
#                                      more CPU; the profiling-diff view
#                                      lights up _extract_features_pairwise
#                                      as a brand-new tower in the flame
#                                      graph that wasn't there before.
FRAUD_FEATURE_EXTRACTOR_ENABLED = _env_bool("FRAUD_FEATURE_EXTRACTOR_ENABLED", False)
FRAUD_FEATURE_COUNT = max(1, int(_env_float("FRAUD_FEATURE_COUNT", 96.0)))
CPU_REGRESSION_ENABLED = _env_bool("CPU_REGRESSION_ENABLED", False)

# --- Kafka producer/consumer config ----------------------------------------
KAFKA_PRODUCER_ENABLED = _env_bool("KAFKA_PRODUCER_ENABLED", False)
KAFKA_CONSUMER_ENABLED = _env_bool("KAFKA_CONSUMER_ENABLED", False)
KAFKA_BOOTSTRAP_SERVERS = os.environ.get("KAFKA_BOOTSTRAP_SERVERS", "")
KAFKA_TOPIC = os.environ.get("KAFKA_TOPIC", "payments.settled")
KAFKA_CONSUMER_GROUP = os.environ.get("KAFKA_CONSUMER_GROUP", SERVICE_NAME)
# Splunk APM uses the producer span's peer.service attribute to decide
# which downstream node to draw an edge to. Historically we set this to
# "kafka" so APM would render an inferred broker node between producer
# and consumer; in practice APM did not infer the broker -> consumer
# edge (the consumer side appeared as a floating service map island).
# Set KAFKA_PEER_SERVICE to the *logical* consumer service name (e.g.
# "settlement-service") to draw a direct producer -> consumer edge.
# Default keeps the legacy "kafka" behaviour for backward compatibility.
KAFKA_PEER_SERVICE = os.environ.get("KAFKA_PEER_SERVICE", "kafka")

# --- Read-API endpoints (GET /recent, GET /status/<id>) --------------------
# Demo-only "lookup" endpoints that exist so the SPA has additional traced
# fetches beyond POST /process. Without them the only RUM->APM pivot is on
# the payment-submit click; with them every page navigation that the SPA
# makes (Recent, Payment Status) produces a fresh fetch span and a fresh
# APM trace, which is what the audience expects when they click "View APM
# trace" in a RUM session.
#
# READ_API_RECENT_DOWNSTREAMS  - comma-separated list of services the
#                                /recent handler should call (one POST
#                                /process each) to enrich the trace. Empty
#                                => /recent serves the in-memory ring
#                                buffer with no downstream calls (still
#                                visible in APM as a single api-gateway
#                                span, which is enough for the RUM link).
# READ_API_STATUS_DOWNSTREAMS  - same, for /status/<payment_id>. Pointing
#                                this at payment-status-service produces
#                                a 2-service trace which matches the
#                                "look up payment status" story.
# READ_API_RING_SIZE           - max entries kept in the in-memory recent
#                                payments buffer. Bounded so a long-running
#                                pod doesn't grow without bound.
READ_API_RECENT_DOWNSTREAMS = _env_list("READ_API_RECENT_DOWNSTREAMS")
READ_API_STATUS_DOWNSTREAMS = _env_list("READ_API_STATUS_DOWNSTREAMS")
READ_API_RING_SIZE = max(10, int(_env_float("READ_API_RING_SIZE", 200.0)))

# Optional Redis backing for the ring buffer. When set, /recent and
# /status read from Redis instead of the in-process deque, which means
# multi-replica / multi-gunicorn-worker deployments all see the same
# ring buffer (the SPA "submit, then look it up" demo flow then works
# regardless of which pod or worker the GET lands on). Keeping the
# in-process fallback means the unit-test path and any deploy that
# omits Redis still functions, just per-process.
#
#   READ_API_REDIS_URL   - redis://host:port/db. Empty => in-memory.
#   READ_API_REDIS_KEY   - the Redis list key. One key per logical
#                          buffer; isolating from CACHE_URL so the
#                          fraud / sanctions cache demos can't
#                          accidentally evict the read-api state.
READ_API_REDIS_URL = os.environ.get("READ_API_REDIS_URL", "")
READ_API_REDIS_KEY = os.environ.get("READ_API_REDIS_KEY", "natwest:recent_payments")

# Per-process fallback ring buffer. CPython deques are thread-safe for
# append/popleft and we only ever do those + a `list()` snapshot, so no
# explicit lock is needed. Each entry is a small dict (no PII) - just
# enough for the SPA Recent page to render a row.
_RECENT_RING: Deque[dict[str, Any]] = deque(maxlen=READ_API_RING_SIZE)

# Lazy-init the Redis client below, after `log` is configured (so a bad
# URL surfaces a structured warning rather than dying silently before
# logging is set up).
_read_api_redis: Any = None


# Splunk's auto-instrumentation distro and the upstream
# `opentelemetry-instrumentation-kafka-python` package have repeatedly
# disagreed about whether `kafka-python` vs `kafka-python-ng` is supported,
# and the wrapping silently no-ops when their dependency check fails. Rather
# than fight that, we propagate W3C trace context explicitly on every
# Kafka message. This works regardless of which auto-instrumentation is
# active (idempotent: even if the instrumentor IS loaded, the explicit
# inject/extract still produces a valid parent->child link because
# Splunk APM keys async edges on the `traceparent` header).
#
# Helpers below: `_kafka_inject_headers` builds W3C `traceparent` /
# `tracestate` / `baggage` headers from the active span, and
# `_kafka_extract_context` reverses that on the consumer side so we can
# `otel_context.attach()` the extracted parent before creating the
# consumer span.


class JsonFormatter(logging.Formatter):
    """Structured JSON logs with OTel trace/span correlation for Splunk."""

    def format(self, record: logging.LogRecord) -> str:
        span = trace.get_current_span()
        ctx = span.get_span_context() if span is not None else None

        payload: dict[str, Any] = {
            "timestamp": self.formatTime(record, "%Y-%m-%dT%H:%M:%S.%fZ"),
            "level": record.levelname,
            "service": SERVICE_NAME,
            "tier": SERVICE_TIER,
            "logger": record.name,
            "message": record.getMessage(),
        }
        if ctx is not None and ctx.is_valid:
            payload["trace_id"] = format(ctx.trace_id, "032x")
            payload["span_id"] = format(ctx.span_id, "016x")
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, separators=(",", ":"))


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
root_logger = logging.getLogger()
root_logger.handlers = [handler]
root_logger.setLevel(logging.INFO)
logging.getLogger("werkzeug").setLevel(logging.WARNING)
log = logging.getLogger(SERVICE_NAME)

# Optional audit emitter. The module is always importable - emitters
# silently no-op when AUDIT_ENABLED=false (the default for back-end
# services that don't sit on the user-facing edge). When enabled, only
# services that explicitly call emit_payment_audit / emit_auth_event /
# emit_chaos_event produce records, and those land in
# /var/log/audit/audit.jsonl which the audit-tail sidecar tails into the
# nwpay_audit Splunk index.
try:
    from audit import (
        emit_auth_event,
        emit_network_event,
        emit_payment_audit,
        emit_sca_event,
    )
except Exception as _audit_exc:  # noqa: BLE001 - never block startup
    log.warning("audit_module_import_failed err=%s", _audit_exc)
    emit_payment_audit = None  # type: ignore
    emit_auth_event = None  # type: ignore
    emit_network_event = None  # type: ignore
    emit_sca_event = None  # type: ignore

app = Flask(__name__)
tracer = trace.get_tracer(SERVICE_NAME)
_session = requests.Session()
# Outbound HTTP connection-pool sizing. urllib3's default pool is only 10
# connections per host - far smaller than this service's gunicorn concurrency
# (GUNICORN_WORKERS x GUNICORN_THREADS) once DOWNSTREAM_FANOUT spreads each
# request across several downstreams. Under load the pool overflows, urllib3
# discards connections ("Connection pool is full, discarding connection"), and
# the resulting connection churn drives multi-second tail latency plus 6s read
# timeouts on the busiest downstream (e.g. customer-profile-service). Sizing the
# pool to the worker thread count (with headroom) keeps connections reused
# instead of churned. Tunable at runtime via HTTP_POOL_MAXSIZE.
try:
    _http_pool_maxsize = max(10, int(os.environ.get("HTTP_POOL_MAXSIZE", "64")))
except (TypeError, ValueError):
    _http_pool_maxsize = 64
_http_adapter = requests.adapters.HTTPAdapter(
    pool_connections=_http_pool_maxsize,
    pool_maxsize=_http_pool_maxsize,
    max_retries=0,
)
_session.mount("http://", _http_adapter)
_session.mount("https://", _http_adapter)


def _peer_service_request_hook(span: trace.Span, request_obj: Any) -> None:
    """Tag every outbound HTTP client span with the downstream service name.

    Without this, Splunk APM's service map can't unambiguously merge a
    client-side `requests` span with the matching server-side span from the
    receiver, and instead renders the receiver as a separate "inferred"
    node labelled `<host>:<port>` (e.g. `fraud-detection-service:8080`).
    """
    if span is None or not span.is_recording():
        return
    try:
        url = getattr(request_obj, "url", None) or ""
        host = urlparse(url).hostname or ""
    except Exception:  # noqa: BLE001 - never let a hook fail the request
        return
    if not host:
        return
    peer = host.split(".", 1)[0]
    if peer:
        span.set_attribute("peer.service", peer)


# RequestsInstrumentor is auto-enabled by the splunk-py-trace distro at process
# start, so we re-instrument it here with our hook attached. Safe to call
# even if the SDK isn't fully wired up - we silently fall back if the import
# or instrumentation fails (e.g. in a unit test without OTel).
try:
    from opentelemetry.instrumentation.requests import RequestsInstrumentor

    _instrumentor = RequestsInstrumentor()
    if getattr(_instrumentor, "is_instrumented_by_opentelemetry", False):
        _instrumentor.uninstrument()
    _instrumentor.instrument(request_hook=_peer_service_request_hook)
except Exception:  # noqa: BLE001 - hook is best-effort, never block startup
    pass


def _redis_peer_service_hook(span: trace.Span, instance: Any, args: Any, kwargs: Any) -> None:  # noqa: ARG001
    """Tag every redis-py client span with peer.service=redis.

    OTEL_INSTRUMENTATION_COMMON_PEER_SERVICE_MAPPING is honoured reliably
    by the Splunk Java agent but only patchily by the Python contrib
    instrumentations. Without an explicit peer.service, the redis-py
    instrumentation produces spans whose only "downstream identity" is
    `db.system=redis` + `net.peer.name=redis.natwest.svc.cluster.local`,
    so Splunk APM draws the inferred node using the host:port string -
    long, ugly label, no Redis icon. Setting peer.service=redis here
    gives APM a stable short name; combined with db.system=redis it
    renders the Redis branded icon on the service map.

    Note: the IM metrics pipeline (collector/values.yaml prometheus/infra)
    deliberately does NOT advertise service.name=redis - if it did, APM
    would merge this trace-inferred infra node with the metric-side
    service entity and replace the icon with a generic service circle.
    """
    if span is None or not span.is_recording():
        return
    try:
        span.set_attribute("peer.service", "redis")
        span.set_attribute("db.system", "redis")
    except Exception:  # noqa: BLE001 - hook is best-effort, never block startup
        pass


# Same defensive re-instrumentation pattern as RequestsInstrumentor above:
# splunk-py-trace auto-instruments redis at process start without our hook,
# so we uninstrument-then-instrument to attach the peer.service hook.
try:
    from opentelemetry.instrumentation.redis import RedisInstrumentor

    _redis_instrumentor = RedisInstrumentor()
    if getattr(_redis_instrumentor, "is_instrumented_by_opentelemetry", False):
        _redis_instrumentor.uninstrument()
    _redis_instrumentor.instrument(request_hook=_redis_peer_service_hook)
except Exception:  # noqa: BLE001 - hook is best-effort, never block startup
    pass


# --- Redis client (singleton) ----------------------------------------------
_redis_client: Any = None
if CACHE_ENABLED and CACHE_URL:
    try:
        import redis  # type: ignore

        _redis_client = redis.Redis.from_url(
            CACHE_URL,
            socket_timeout=1.0,
            socket_connect_timeout=1.0,
            health_check_interval=30,
        )
        # Best-effort connectivity probe so DNS / unauthenticated failures
        # surface in the pod logs once at startup rather than on every call.
        try:
            _redis_client.ping()
            log.info("cache_connected url=%s namespace=%s", CACHE_URL, CACHE_KEY_NAMESPACE)
        except Exception as exc:  # noqa: BLE001
            log.warning("cache_ping_failed url=%s err=%s", CACHE_URL, exc)
    except Exception as exc:  # noqa: BLE001
        log.warning("cache_init_failed err=%s", exc)
        _redis_client = None


# --- Read-API Redis client (separate from CACHE_URL so the demo cache
# eviction story can't ever clear the SPA's recent-payments buffer). ------
if READ_API_REDIS_URL:
    try:
        import redis as _redis_mod  # type: ignore

        _read_api_redis = _redis_mod.Redis.from_url(
            READ_API_REDIS_URL,
            socket_timeout=1.0,
            socket_connect_timeout=1.0,
            health_check_interval=30,
        )
        try:
            _read_api_redis.ping()
            log.info(
                "read_api_redis_connected url=%s key=%s",
                READ_API_REDIS_URL,
                READ_API_REDIS_KEY,
            )
        except Exception as exc:  # noqa: BLE001
            log.warning(
                "read_api_redis_ping_failed url=%s err=%s", READ_API_REDIS_URL, exc
            )
    except Exception as exc:  # noqa: BLE001
        log.warning("read_api_redis_init_failed err=%s", exc)
        _read_api_redis = None


# Status entries get an explicit TTL so a SPA-submitted payment stays
# findable long after it's aged out of the chronological /recent list
# (the traffic-generator pushes ~25 RPS and would otherwise evict any
# single user click within seconds). 1 hour is plenty for the demo's
# "submit, browse around, look it up" arc.
READ_API_STATUS_TTL_S = max(60, int(_env_float("READ_API_STATUS_TTL_S", 3600.0)))


def _status_key(payment_id: str) -> str:
    return f"{READ_API_REDIS_KEY}:status:{payment_id}"


def _record_recent(entry: dict[str, Any]) -> None:
    """Append a recent-payment entry to the shared store.

    Two parallel writes when Redis is configured:
      - LPUSH + LTRIM on the chronological list (powers /recent display)
      - SETEX on a per-id key (powers /status lookup, survives churn)

    Falls back to the in-process deque when Redis is absent so unit
    tests and any deploy that omits Redis still work - just per-process.
    """
    if _read_api_redis is not None:
        try:
            payload = json.dumps(entry, separators=(",", ":"))
            pipe = _read_api_redis.pipeline()
            pipe.lpush(READ_API_REDIS_KEY, payload)
            pipe.ltrim(READ_API_REDIS_KEY, 0, READ_API_RING_SIZE - 1)
            pid = entry.get("payment_id")
            if pid:
                pipe.setex(_status_key(pid), READ_API_STATUS_TTL_S, payload)
            pipe.execute()
            return
        except Exception as exc:  # noqa: BLE001 - never let the read-api
            # path break payment processing. Fall through to in-process.
            log.debug("read_api_redis_write_failed err=%s", exc)
    _RECENT_RING.append(entry)


def _list_recent(limit: int) -> list[dict[str, Any]]:
    """Return up to `limit` most-recent entries, newest first."""
    if _read_api_redis is not None:
        try:
            raw = _read_api_redis.lrange(READ_API_REDIS_KEY, 0, max(0, limit - 1))
            return [json.loads(r) for r in raw]
        except Exception as exc:  # noqa: BLE001
            log.debug("read_api_redis_read_failed err=%s", exc)
    items = list(_RECENT_RING)[-limit:]
    items.reverse()
    return items


def _find_recent(payment_id: str) -> dict[str, Any] | None:
    """Look up an entry by payment id.

    Redis path is O(1) GET on the per-id key; the chronological list is
    only consulted for the in-process fallback. Returns None when the
    id has never been recorded or has aged past READ_API_STATUS_TTL_S.
    """
    if _read_api_redis is not None:
        try:
            raw = _read_api_redis.get(_status_key(payment_id))
            if raw is None:
                return None
            return json.loads(raw)
        except Exception as exc:  # noqa: BLE001
            log.debug("read_api_redis_lookup_failed err=%s", exc)
    for entry in reversed(_RECENT_RING):
        if entry.get("payment_id") == payment_id:
            return entry
    return None


def _cache_lookup(key_payload: str) -> bool:
    """Return True if the cache returned a hit for `key_payload`.

    The actual key is `<namespace>:<sha1>`; we GET it on every call. If
    Redis is reachable the OTel redis-py instrumentation produces a
    `db.system=redis` client span linked to the current trace, which Splunk
    APM renders as an inferred-infrastructure node ("redis").

    The hit/miss decision is *deterministic for a given key* via the cached
    flag, with random sampling controlled by CACHE_HIT_RATE. We seed cache
    contents on the fly: on a "hit" we set the key (so subsequent calls for
    the same payment are also hits), on a "miss" we leave it unset.
    """
    if _redis_client is None:
        return False
    cache_key = f"{CACHE_KEY_NAMESPACE}:{hashlib.sha1(key_payload.encode()).hexdigest()}"
    try:
        cached = _redis_client.get(cache_key)
        if cached is not None:
            return True
        # Decide whether to "warm" the cache for this key, weighted by hit rate.
        if random.random() < CACHE_HIT_RATE:
            try:
                _redis_client.setex(cache_key, 300, "1")
            except Exception:  # noqa: BLE001
                pass
            return True
        return False
    except Exception as exc:  # noqa: BLE001
        # Don't let cache failures take the request down; we fall back to the
        # uncached code path which is the desired blast-radius behaviour.
        log.debug("cache_lookup_failed key=%s err=%s", cache_key, exc)
        return False


# --- Kafka producer (singleton) --------------------------------------------
_kafka_producer: Any = None
if KAFKA_PRODUCER_ENABLED and KAFKA_BOOTSTRAP_SERVERS:
    try:
        from kafka import KafkaProducer  # type: ignore

        _kafka_producer = KafkaProducer(
            bootstrap_servers=[s.strip() for s in KAFKA_BOOTSTRAP_SERVERS.split(",") if s.strip()],
            value_serializer=lambda v: json.dumps(v).encode("utf-8"),
            client_id=f"{SERVICE_NAME}-producer",
            request_timeout_ms=2000,
            api_version_auto_timeout_ms=2000,
            acks=1,
            retries=2,
            linger_ms=5,
        )
        log.info("kafka_producer_connected bootstrap=%s topic=%s", KAFKA_BOOTSTRAP_SERVERS, KAFKA_TOPIC)
    except Exception as exc:  # noqa: BLE001
        log.warning("kafka_producer_init_failed err=%s", exc)
        _kafka_producer = None


def _kafka_inject_headers() -> list[tuple[str, bytes]]:
    """Serialize the active OTel context into kafka-python headers.

    `propagate.inject()` writes into a dict via the configured global text
    map propagator (W3C tracecontext + baggage by default). kafka-python
    expects headers as a list of (name, bytes) tuples, so we adapt.
    """
    carrier: dict[str, str] = {}
    propagate.inject(carrier)
    return [(k, v.encode("utf-8")) for k, v in carrier.items()]


def _publish_settlement(payment_id: str, payload: dict[str, Any]) -> None:
    """Publish a settlement message to Kafka. Fire-and-forget; failures logged.

    Wraps the actual `KafkaProducer.send` in a producer span (kind=PRODUCER)
    and injects W3C trace context into the message headers so the consumer-
    side span links back to the payment-init request as a parent. Splunk APM
    uses these messaging.* attributes to render the dotted async edge in the
    service map.
    """
    if _kafka_producer is None:
        return

    tracer = trace.get_tracer(__name__)
    # Span name follows OTel messaging semantic conventions: "<destination> send".
    span_name = f"{KAFKA_TOPIC} send"
    try:
        with tracer.start_as_current_span(span_name, kind=SpanKind.PRODUCER) as span:
            span.set_attribute("messaging.system", "kafka")
            span.set_attribute("messaging.destination.name", KAFKA_TOPIC)
            span.set_attribute("messaging.destination.kind", "topic")
            span.set_attribute("messaging.operation", "publish")
            # peer.service is what Splunk APM uses to label the downstream
            # node on the service map. We previously set this to "kafka"
            # in the hope APM would render an inferred broker node and
            # chain producer -> kafka -> consumer; in practice the
            # consumer side appeared as a disconnected service map
            # island (no edge was drawn from the inferred kafka node).
            # Setting peer.service to the *logical* consumer service
            # (configured via KAFKA_PEER_SERVICE) draws a direct
            # producer -> consumer edge. The messaging.* attributes
            # below still tell APM this is a Kafka-mediated async hop,
            # so the edge is rendered as a dotted async edge in the
            # service map (not a solid sync one).
            span.set_attribute("peer.service", KAFKA_PEER_SERVICE)
            span.set_attribute("payment.id", payment_id)
            for k in (
                "scheme",
                "amount_minor_units",
                "currency",
                "country_pair",
                "originator_country",
                "beneficiary_country",
                "channel",
                "amount_bucket",
                "scenario",
            ):
                v = payload.get(k)
                if v is not None:
                    span.set_attribute(f"payment.{k}", v)

            headers = _kafka_inject_headers()
            future = _kafka_producer.send(
                KAFKA_TOPIC,
                value={
                    "payment_id": payment_id,
                    "scheme": payload.get("scheme"),
                    "amount_minor_units": payload.get("amount_minor_units"),
                    "currency": payload.get("currency"),
                    "country_pair": payload.get("country_pair"),
                    "originator_country": payload.get("originator_country"),
                    "beneficiary_country": payload.get("beneficiary_country"),
                    "channel": payload.get("channel"),
                    "amount_bucket": payload.get("amount_bucket"),
                    "scenario": payload.get("scenario"),
                    "from": SERVICE_NAME,
                    "ts": int(time.time() * 1000),
                },
                headers=headers,
            )
            # Don't .get() - we want this off the request critical path. The
            # producer batches in the background and any error surfaces on the
            # next call.
            del future
    except Exception as exc:  # noqa: BLE001
        log.warning("kafka_publish_failed err=%s", exc)


# --- Kafka consumer (background thread) ------------------------------------
def _kafka_extract_context(headers: list[tuple[str, bytes]] | None):
    """Rebuild a parent OTel context from kafka-python message headers.

    Mirrors `_kafka_inject_headers`: kafka-python delivers headers as a list
    of (name, bytes) tuples, but `propagate.extract()` expects a Mapping[str, str].
    Returns the new context (callers should attach() it for the lifetime of
    the consumer span).
    """
    if not headers:
        return otel_context.get_current()
    carrier: dict[str, str] = {}
    for name, raw in headers:
        try:
            carrier[name] = raw.decode("utf-8")
        except (UnicodeDecodeError, AttributeError):
            continue
    return propagate.extract(carrier)


def _handle_kafka_message(msg: Any) -> None:
    """Process one Kafka message inside a CONSUMER span linked to the producer.

    The producer side injected W3C traceparent into the message headers; we
    extract that here and use it as the parent context, so Splunk APM stitches
    payment-init -> kafka -> settlement-service into a single trace and draws
    the dotted async edge in the service map.
    """
    body = msg.value or {}
    payment_id = body.get("payment_id") or "unknown"

    parent_ctx = _kafka_extract_context(getattr(msg, "headers", None))
    tracer = trace.get_tracer(__name__)
    span_name = f"{KAFKA_TOPIC} process"

    with tracer.start_as_current_span(
        span_name, context=parent_ctx, kind=SpanKind.CONSUMER
    ) as span:
        span.set_attribute("messaging.system", "kafka")
        span.set_attribute("messaging.destination.name", KAFKA_TOPIC)
        span.set_attribute("messaging.destination.kind", "topic")
        span.set_attribute("messaging.operation", "process")
        # Deliberately do NOT set peer.service on the CONSUMER span.
        # Splunk APM interprets CONSUMER + peer.service as an OUTBOUND
        # edge from this service to that peer, which would draw a
        # nonsensical "settlement-service -> kafka" arrow on the
        # service map. The inbound edge from the producer is already
        # drawn via the producer-side peer.service (see
        # _publish_settlement) and the parent_span_id linkage carried
        # in the Kafka message headers, so this side does not need
        # any peer attribute to participate in the topology.
        span.set_attribute("messaging.kafka.consumer.group", KAFKA_CONSUMER_GROUP)
        if hasattr(msg, "partition"):
            span.set_attribute("messaging.kafka.partition", msg.partition)
        if hasattr(msg, "offset"):
            span.set_attribute("messaging.kafka.message.offset", msg.offset)
        span.set_attribute("payment.id", payment_id)
        span.set_attribute("service.tier", SERVICE_TIER)
        for k in (
            "scheme",
            "amount_minor_units",
            "currency",
            "country_pair",
            "originator_country",
            "beneficiary_country",
            "channel",
            "amount_bucket",
            "scenario",
        ):
            v = body.get(k)
            if v is not None:
                span.set_attribute(f"payment.{k}", v)

        work_ms, _ = _simulate_local_work()

        # Fan-out to downstreams just like /process so the async branch of
        # the trace shows the same shape (settlement -> reconciliation ->
        # reporting in the topology).
        downstreams = _select_downstreams()
        if downstreams:
            with ThreadPoolExecutor(max_workers=MAX_FANOUT_WORKERS) as pool:
                futures = [
                    pool.submit(_call_downstream, svc, body) for svc in downstreams
                ]
                for fut in as_completed(futures):
                    fut.result()
        log.info(
            "kafka_consumed payment_id=%s scheme=%s work_ms=%.1f downstreams=%d",
            payment_id, body.get("scheme"), work_ms, len(downstreams),
        )


def _consumer_loop() -> None:
    """Run a Kafka consumer loop in a daemon thread.

    For each message, do one /process-equivalent: simulate work and call
    downstreams. The producer side injected W3C traceparent into the Kafka
    headers; `_handle_kafka_message` extracts that context and starts the
    consumer span as a child, giving Splunk APM a continuous trace across
    the async edge.
    """
    while True:
        try:
            from kafka import KafkaConsumer  # type: ignore

            consumer = KafkaConsumer(
                KAFKA_TOPIC,
                bootstrap_servers=[
                    s.strip() for s in KAFKA_BOOTSTRAP_SERVERS.split(",") if s.strip()
                ],
                client_id=f"{SERVICE_NAME}-consumer",
                group_id=KAFKA_CONSUMER_GROUP,
                auto_offset_reset="latest",
                enable_auto_commit=True,
                value_deserializer=lambda v: json.loads(v.decode("utf-8")),
            )
            log.info(
                "kafka_consumer_connected bootstrap=%s topic=%s group=%s",
                KAFKA_BOOTSTRAP_SERVERS, KAFKA_TOPIC, KAFKA_CONSUMER_GROUP,
            )
            for msg in consumer:
                try:
                    _handle_kafka_message(msg)
                except Exception as exc:  # noqa: BLE001
                    log.warning("kafka_message_handler_failed err=%s", exc)
        except Exception as exc:  # noqa: BLE001
            log.warning("kafka_consumer_loop_error err=%s - retrying in 5s", exc)
            time.sleep(5.0)


_consumer_thread_started = False
_consumer_thread_lock = threading.Lock()


def _ensure_consumer_started() -> None:
    """Start the consumer once per process. Safe to call from any worker."""
    global _consumer_thread_started
    if not (KAFKA_CONSUMER_ENABLED and KAFKA_BOOTSTRAP_SERVERS):
        return
    with _consumer_thread_lock:
        if _consumer_thread_started:
            return
        t = threading.Thread(target=_consumer_loop, name="kafka-consumer", daemon=True)
        t.start()
        _consumer_thread_started = True
        log.info("kafka_consumer_thread_started topic=%s", KAFKA_TOPIC)


def _simulate_local_work(force_skip_tail: bool = False) -> tuple[float, bool]:
    """Sleep for a gaussian-distributed duration, optionally with a tail spike.

    Returns (ms_slept, tail_injected). When TAIL_LATENCY_RATE > 0 and we have
    *not* hit a cache, with probability TAIL_LATENCY_RATE we add a uniform
    sleep on top of the gaussian work to model the kind of long-tail you'd
    see from a contended DB or an external API occasionally degrading.
    """
    delay_ms = max(0.0, random.gauss(LATENCY_MEAN, LATENCY_STD))
    tail = False
    if (
        not force_skip_tail
        and TAIL_LATENCY_RATE > 0.0
        and random.random() < TAIL_LATENCY_RATE
    ):
        delay_ms += random.uniform(TAIL_LATENCY_MIN_MS, TAIL_LATENCY_MAX_MS)
        tail = True
    time.sleep(delay_ms / 1000.0)
    return delay_ms, tail


class RegionalDependencyError(Exception):
    """A region-scoped downstream dependency (e.g. the EU-South AML screening
    provider) is degraded. Recorded on the active span via record_exception so
    the APM trace shows a descriptive root cause (type + message) rather than a
    bare 5xx - this is the "why did it happen" half of the demo story."""


def _maybe_inject_location_degradation(
    customer_country: str | None, payment_id: str, span: Any
) -> tuple[Any, int] | None:
    """Location-scoped latency + optional error injection.

    No-op unless SLOW_LOCATION_COUNTRY is armed AND the incoming payment's
    customer_country matches it. When it matches the latency is spent inside
    CLIENT child span(s) that model the outbound call to the external AML
    screening provider (peer.service => an inferred provider node on the APM
    service map). With probability SLOW_LOCATION_ERROR_RATE the primary call
    "times out" and a secondary failover call also fails, each recording a
    RegionalDependencyError; we then mark the service span as the errored root
    cause, emit a trace-correlated structured log, and return a 5xx. Returns a
    (response, status) tuple to short-circuit the handler on error, else None.

    Latency stays well under the 6 s default downstream timeout, so the caller
    sees a clean long/errored span rather than a read-timeout cascade.
    """
    if not SLOW_LOCATION_COUNTRY or SLOW_LOCATION_LATENCY_MS <= 0.0:
        return None
    if (customer_country or "").strip().upper() != SLOW_LOCATION_COUNTRY:
        return None

    extra_ms = SLOW_LOCATION_LATENCY_MS
    if SLOW_LOCATION_JITTER_MS > 0.0:
        extra_ms = max(0.0, random.gauss(SLOW_LOCATION_LATENCY_MS, SLOW_LOCATION_JITTER_MS))
    if span is not None and span.is_recording():
        span.set_attribute("payment.location_degraded", True)
        span.set_attribute("degradation.region", SLOW_LOCATION_COUNTRY)
        span.set_attribute("degradation.dependency", SLOW_LOCATION_DEPENDENCY)
        span.set_attribute("degradation.injected_latency_ms", round(extra_ms, 0))

    will_error = SLOW_LOCATION_ERROR_RATE > 0.0 and random.random() < SLOW_LOCATION_ERROR_RATE

    # Attributes shared by both provider-call child spans. peer.service makes
    # Splunk APM render an *inferred downstream node* for the external screening
    # provider (same mechanism the Kafka producer span uses), so the trace and
    # service map literally show "sanctions-aml-service -> aml-screening-provider
    # -eu-south" with the failing edge - not just an exception on the service
    # span.
    provider_attrs = {
        "peer.service": SLOW_LOCATION_DEPENDENCY,
        "net.peer.name": SLOW_LOCATION_DEPENDENCY,
        "server.address": SLOW_LOCATION_DEPENDENCY,
        "aml.screening.region": SLOW_LOCATION_COUNTRY,
        "http.request.method": "POST",
        "url.path": "/v1/screen",
    }

    # --- Outbound call to the PRIMARY screening provider, modelled as a CLIENT
    # child span so it appears as a real dependency call in the waterfall.
    with tracer.start_as_current_span(
        f"POST {SLOW_LOCATION_DEPENDENCY} (primary)", kind=SpanKind.CLIENT
    ) as primary:
        for _k, _v in provider_attrs.items():
            primary.set_attribute(_k, _v)
        primary.set_attribute("aml.provider.role", "primary")
        if will_error:
            # Primary burns ~80% of the budget then times out.
            primary_ms = extra_ms * 0.8
            time.sleep(primary_ms / 1000.0)
            primary_exc = RegionalDependencyError(
                f"{SLOW_LOCATION_DEPENDENCY}: primary AML screening provider for region "
                f"{SLOW_LOCATION_COUNTRY} timed out after {primary_ms:.0f} ms"
            )
            primary.record_exception(primary_exc)
            primary.set_status(Status(StatusCode.ERROR, str(primary_exc)))
            primary.set_attribute("error", True)
            primary.set_attribute("error.type", "provider_timeout")
        else:
            # Degraded-but-alive: slow, but the screening still returns clear.
            time.sleep(extra_ms / 1000.0)
            primary.set_attribute("aml.screening.result", "clear")

    if not will_error:
        return None

    # --- Failover to the SECONDARY provider, which also fails -> no healthy
    # screening path -> the request 5xx's. A second CLIENT span makes the
    # "primary timed out, secondary failover exhausted" story literal.
    exc = RegionalDependencyError(
        f"{SLOW_LOCATION_DEPENDENCY}: primary AML screening provider for region "
        f"{SLOW_LOCATION_COUNTRY} timed out after {extra_ms:.0f} ms; secondary "
        f"failover exhausted"
    )
    with tracer.start_as_current_span(
        f"POST {SLOW_LOCATION_DEPENDENCY} (secondary failover)", kind=SpanKind.CLIENT
    ) as secondary:
        for _k, _v in provider_attrs.items():
            secondary.set_attribute(_k, _v)
        secondary.set_attribute("aml.provider.role", "secondary")
        time.sleep((extra_ms * 0.2) / 1000.0)
        secondary.record_exception(exc)
        secondary.set_status(Status(StatusCode.ERROR, str(exc)))
        secondary.set_attribute("error", True)
        secondary.set_attribute("error.type", "regional_dependency_timeout")

    # Mark the sanctions-aml-service span itself as the errored root cause too,
    # so it shows red on the service map and in the trace header.
    if span is not None and span.is_recording():
        span.record_exception(exc)
        span.set_status(Status(StatusCode.ERROR, str(exc)))
        span.set_attribute("error", True)
        span.set_attribute("error.type", "regional_dependency_timeout")

    # Trace-correlated structured log so "Logs for this trace" in APM shows the
    # deeper why (region + dependency + payment id).
    log.error(
        json.dumps(
            {
                "event": "regional_dependency_timeout",
                "service": SERVICE_NAME,
                "payment_id": payment_id,
                "region": SLOW_LOCATION_COUNTRY,
                "dependency": SLOW_LOCATION_DEPENDENCY,
                "injected_latency_ms": round(extra_ms, 0),
                "message": str(exc),
            }
        )
    )
    return (
        jsonify(
            {
                "service": SERVICE_NAME,
                "payment_id": payment_id,
                "error": "regional_dependency_timeout",
                "region": SLOW_LOCATION_COUNTRY,
            }
        ),
        500,
    )


def _extract_features_linear(seed: str, n: int) -> int:
    """O(N) fingerprint kernel - the baseline fraud feature extractor.

    Hashes N derived strings once each. Cheap and CPU-flat. Shows up in the
    AlwaysOn Profiling flame graph as a small, predictable hump under
    `_compute_fraud_features` -> `_extract_features_linear`.
    """
    digest = 0
    for i in range(n):
        digest ^= int.from_bytes(
            hashlib.blake2b(f"{seed}:{i}".encode(), digest_size=8).digest(),
            "little",
        )
    return digest


def _extract_features_pairwise(seed: str, n: int) -> int:
    """O(N^2) pairwise fingerprint kernel - the CPU regression pathology.

    Functionally equivalent (returns a stable digest), but the inner loop
    is a quadratic explosion: ~N(N-1)/2 hash calls instead of N. With the
    default N=96 this is ~30x more CPU than the linear path, which is
    enough to dominate the service's flame graph and show up unmistakably
    in the Splunk APM AlwaysOn Profiling diff view.

    The function is intentionally named `_extract_features_pairwise` so
    the new tower in the flame graph reads like a regression that snuck
    in via a "smarter" feature engineering PR - the typical complaint
    that profiling diff is designed to catch.
    """
    digest = 0
    for i in range(n):
        for j in range(i + 1, n):
            digest ^= int.from_bytes(
                hashlib.blake2b(f"{seed}:{i}:{j}".encode(), digest_size=8).digest(),
                "little",
            )
    return digest


def _compute_fraud_features(payment_id: str) -> None:
    """Run the configured fraud feature extractor under a named child span.

    The span name (`compute_fraud_features`) and the algorithm attribute
    are what Splunk APM groups by, so flipping CPU_REGRESSION_ENABLED at
    runtime produces two cleanly comparable populations of spans for the
    profiling-diff demo beat.
    """
    tracer_local = trace.get_tracer(__name__)
    with tracer_local.start_as_current_span("compute_fraud_features") as fspan:
        fspan.set_attribute("fraud.feature_count", FRAUD_FEATURE_COUNT)
        fspan.set_attribute(
            "fraud.algo", "pairwise" if CPU_REGRESSION_ENABLED else "linear"
        )
        if CPU_REGRESSION_ENABLED:
            _extract_features_pairwise(payment_id, FRAUD_FEATURE_COUNT)
        else:
            _extract_features_linear(payment_id, FRAUD_FEATURE_COUNT)


def _select_downstreams() -> list[str]:
    if not DOWNSTREAMS:
        return []
    if DOWNSTREAM_FANOUT == "all":
        return list(DOWNSTREAMS)
    if DOWNSTREAM_FANOUT.startswith("random:"):
        try:
            n = int(DOWNSTREAM_FANOUT.split(":", 1)[1])
        except (IndexError, ValueError):
            n = len(DOWNSTREAMS)
        n = max(1, min(n, len(DOWNSTREAMS)))
        return random.sample(DOWNSTREAMS, n)
    return list(DOWNSTREAMS)


def _call_downstream(service: str, payload: dict[str, Any]) -> dict[str, Any]:
    url = f"{DOWNSTREAM_SCHEME}://{service}:{DOWNSTREAM_PORT}/process"
    try:
        resp = _session.post(url, json=payload, timeout=DOWNSTREAM_TIMEOUT_S)
        return {
            "service": service,
            "status": resp.status_code,
            "ok": resp.ok,
        }
    except requests.RequestException as exc:
        log.warning("downstream_call_failed service=%s error=%s", service, exc)
        return {"service": service, "status": 0, "ok": False}


@app.post("/api/auth/event")
@app.post("/auth/event")
def auth_event() -> Any:
    """Audit beacon for the SPA login / logout flow.

    The SPA is currently a client-side gate - the password digest never
    leaves the browser - so this endpoint is intentionally a beacon, not
    an authoritative auth check (codeguard-0-authentication-mfa: this
    is documented in frontend/src/AuthContext.tsx as demo-grade and
    needs server-side verification before any production use).

    The endpoint accepts a small JSON payload from the SPA's login form
    and emits a structured audit event into the nwpay_audit Splunk
    index. Anti-injection / abuse considerations:

      * Only the gateway tier accepts this beacon; emit_auth_event
        no-ops elsewhere (see import guard).
      * Username is server-coerced to <= 64 chars and outcome is
        allow-listed inside emit_auth_event; client-supplied values
        cannot widen the schema.
      * Returns 204 on every code path to avoid auth-state oracling
        (codeguard-0-authentication-mfa: "Always return generic error
        messages... Keep timing consistent to prevent account enumeration.")
    """
    if SERVICE_TIER != "gateway" or emit_auth_event is None:
        # Not a gateway pod, or audit module failed to import. Silently
        # accept and drop so the SPA's request doesn't fail.
        return ("", 204)

    body = request.get_json(silent=True) or {}
    username = body.get("username") or ""
    outcome = body.get("outcome") or "failed"
    mfa = bool(body.get("mfa", False))

    # Prefer X-Forwarded-For (behind the SPA reverse proxy) but trust
    # only the first hop. The reverse proxy is configured upstream so
    # this header is set; remote_addr is a sane fallback.
    xff = request.headers.get("X-Forwarded-For", "")
    client_ip = (xff.split(",")[0].strip() if xff else request.remote_addr) or None
    user_agent = request.headers.get("User-Agent")

    try:
        emit_auth_event(
            username=username,
            outcome=outcome,
            client_ip=client_ip,
            user_agent=user_agent,
            mfa=mfa,
        )
    except Exception as exc:  # noqa: BLE001 - never fail the beacon
        log.warning("auth_event_emit_failed err=%s", exc)

    # PSD2 Strong Customer Authentication audit. Every successful login
    # in the SPA conceptually counts as one SCA challenge in this demo
    # (real banks invoke SCA on a subset of operations). The challenge
    # method + outcome are synthesised from the username so the demo
    # produces a varied but stable distribution: olivia/james use
    # passkeys, margaret uses SMS OTP, admin uses a hardware token.
    # 5% of attempts are recorded as failed/abandoned so the SCA pass
    # rate panel doesn't sit at 100%.
    if emit_sca_event is not None:
        try:
            uname_lower = (username or "").lower()
            method_map = {
                "olivia":   "passkey",
                "james":    "biometric_face",
                "margaret": "sms_otp",
                "admin":    "hardware_token",
            }
            sca_method = method_map.get(uname_lower, "push_notification")
            # Synthesise a deterministic outcome distribution from the
            # client_ip last byte so the same persona doesn't always
            # pass; gives panels a realistic non-100% pass rate.
            try:
                last_byte = int((client_ip or "0.0.0.0").split(".")[-1])
            except (ValueError, AttributeError):
                last_byte = 0
            sca_outcome = "passed"
            sca_exemption = None
            # Weekend evenings show a markedly higher SCA exemption rate in
            # real PSD2 traffic: more leisure spending qualifies for the
            # low-value (RTS Art 16) and contactless-low-value (RTS Art 11)
            # exemptions, plus more recurring-payment renewals settle on
            # Friday/Saturday nights. Bump the exemption threshold from the
            # weekday baseline 12% (last_byte % 100 in [5, 17)) to 25%
            # (last_byte % 100 in [5, 30)) during the Fri-Sat-Sun evening
            # band. The audit / SCA-exemption-rate panel pivots on this.
            exemption_ceiling = 17
            now = dt.datetime.now()
            weekday = now.weekday()
            hour = now.hour
            is_friday_evening = (weekday == 4 and hour >= 18)
            is_weekend_day = weekday in (5, 6)
            if is_friday_evening or is_weekend_day:
                exemption_ceiling = 30
            if outcome != "success":
                sca_outcome = "failed"
            elif last_byte % 100 < 3:
                sca_outcome = "abandoned"
            elif last_byte % 100 < 5:
                sca_outcome = "expired"
            elif last_byte % 100 < exemption_ceiling:
                # Pick an exemption type. Three-way split on the last
                # byte so dashboards see all three exemption codes during
                # weekend hours, not just two.
                mod3 = last_byte % 3
                if mod3 == 0:
                    sca_exemption = "low_value"
                elif mod3 == 1:
                    sca_exemption = "transaction_risk_analysis"
                else:
                    sca_exemption = "contactless_low_value"
            emit_sca_event(
                username=username,
                sca_method=sca_method,
                sca_outcome=sca_outcome,
                sca_exemption=sca_exemption,
                # Risk score in [0,1]: lower for first-party SCA, higher
                # when an exemption is invoked (since TRA is by definition
                # a risk-based decision).
                risk_score=0.32 if sca_exemption == "transaction_risk_analysis" else 0.05,
                duration_ms=420 + (last_byte * 7) % 1500,
            )
        except Exception as exc:  # noqa: BLE001 - never fail the beacon
            log.warning("sca_event_emit_failed err=%s", exc)
    return ("", 204)


@app.post("/api/network/event")
@app.post("/network/event")
def network_event() -> Any:
    """Audit beacon for the SPA's Network Information API state.

    Bridges the browser's reported network conditions
    (effective_type / downlink / rtt / save-data) into Splunk
    Enterprise so ITSI can correlate connectivity flips with
    payment failures. The same data lives in Splunk Observability
    Cloud (RUM) as the `network.context` recordPageAction span,
    but RUM data is not reachable from ITSI today; this beacon
    closes that gap without the audience having to context-switch
    to Observability for the network angle.

    Anti-injection / abuse considerations
    (codeguard-0-input-validation-injection,
    codeguard-0-api-web-services):
      * Gateway-only - non-gateway tiers silently 204 to avoid
        leaking topology to a probe.
      * Every field is server-coerced or clamped inside
        emit_network_event (effective_type via _KNOWN_NETWORK_TYPES,
        downlink in [0, 1000], rtt in [0, 60000]). A malicious
        caller cannot widen the schema or smuggle PII.
      * Returns 204 on every code path so a probe cannot tell
        "audit dropped" from "audit accepted".
    """
    if SERVICE_TIER != "gateway" or emit_network_event is None:
        return ("", 204)

    body = request.get_json(silent=True) or {}

    # Numeric fields - coerced via float()/int() with TypeError swallowed
    # so a hostile string can't crash the beacon. Clamping happens inside
    # emit_network_event for defence in depth.
    def _maybe_float(v: Any) -> float | None:
        try:
            return float(v) if v is not None else None
        except (TypeError, ValueError):
            return None

    def _maybe_int(v: Any) -> int | None:
        try:
            return int(v) if v is not None else None
        except (TypeError, ValueError):
            return None

    xff = request.headers.get("X-Forwarded-For", "")
    client_ip = (xff.split(",")[0].strip() if xff else request.remote_addr) or None
    user_agent = request.headers.get("User-Agent")

    try:
        emit_network_event(
            session_id=body.get("session_id"),
            customer_id=body.get("customer_id"),
            customer_tier=body.get("customer_tier"),
            effective_type=body.get("effective_type"),
            previous_effective_type=body.get("previous_effective_type"),
            downlink_mbps=_maybe_float(body.get("downlink_mbps")),
            rtt_ms=_maybe_int(body.get("rtt_ms")),
            save_data=bool(body.get("save_data", False)),
            source=body.get("source") or "change",
            client_ip=client_ip,
            user_agent=user_agent,
        )
    except Exception as exc:  # noqa: BLE001 - never fail the beacon
        log.warning("network_event_emit_failed err=%s", exc)

    return ("", 204)


@app.get("/healthz")
def healthz() -> Any:
    return jsonify({"status": "ok", "service": SERVICE_NAME})


@app.get("/readyz")
def readyz() -> Any:
    return jsonify({"status": "ready", "service": SERVICE_NAME})


# ---------------------------------------------------------------------------
# Presenter HUD support: read-only mirror of the chaos env vars set by
# scripts/incident.sh on the gateway. Closed allow-list of variable names
# means a hostile caller cannot probe arbitrary process env (which would
# include AWS / Splunk credentials). Empty values are surfaced as empty
# strings so the HUD can tell "var unset" from "var=0.0" without a second
# round-trip.
#
# Only the gateway tier responds with real data — every other pod returns
# an empty payload, by design: the HUD is presenter UI plumbing, not a
# generic introspection API. The endpoint is intentionally unauthenticated
# (the api-gateway sits behind an in-cluster Service + nginx public proxy;
# the values exposed are all already discoverable via `kubectl set env`
# from any operator with cluster access). For production this would
# require an authenticated /admin route — see the talk track's "Phase 2"
# section for the broader auth story.
# ---------------------------------------------------------------------------

_HUD_ENV_ALLOW_LIST = (
    "ERROR_RATE",
    "CACHE_HIT_RATE",
    "DB_LATENCY_MS",
    "CPU_REGRESSION_ENABLED",
    "TIER_THROTTLE_PROB",
    "TIER_FRAUD_FAST_PATH_PROB",
    "TAIL_LATENCY_RATE",
)


@app.get("/api/admin/incident/status")
@app.get("/admin/incident/status")
def admin_incident_status() -> Any:
    if SERVICE_TIER != "gateway":
        return jsonify({"service": SERVICE_NAME, "tier": SERVICE_TIER, "vars": {}})

    # Materialise only the allow-listed keys; everything else stays
    # invisible to the caller. `os.environ.get` is intentionally used
    # (rather than indexing) so a missing key surfaces as None / "".
    vars_out: dict[str, str] = {}
    for key in _HUD_ENV_ALLOW_LIST:
        val = os.environ.get(key, "")
        # Coerce to string and cap at 256 chars to keep the payload tight
        # and prevent any oddly-large env value from blowing up the JSON.
        vars_out[key] = str(val)[:256]

    return jsonify(
        {
            "service": SERVICE_NAME,
            "tier": SERVICE_TIER,
            "deployment_environment": os.environ.get(
                "OTEL_RESOURCE_DEPLOYMENT_ENVIRONMENT", "demo"
            ),
            "vars": vars_out,
        }
    )


@app.post("/process")
def process() -> Any:
    body = request.get_json(silent=True) or {}
    payment_id = body.get("payment_id") or str(uuid.uuid4())
    scenario = body.get("scenario", "generic")
    amount_minor_units = int(body.get("amount_minor_units", 0))

    # Business attributes carried end-to-end so every service's span gets the
    # same dimensions (powers Splunk APM Tag Spotlight pivots).
    scheme = (body.get("scheme") or "").upper() or None
    amount_bucket = body.get("amount_bucket") or None
    currency = body.get("currency") or None
    channel = body.get("channel") or None
    country_pair = body.get("country_pair") or None
    originator_country = body.get("originator_country") or None
    beneficiary_country = body.get("beneficiary_country") or None

    # Customer tier (Bronze/Silver/Gold) and stable customer id. Default to
    # bronze when missing so every span gets a populated dimension - this
    # keeps the by-tier dashboards from collapsing when older traffic
    # arrives (e.g. synthetic checks that haven't been re-rolled yet).
    customer_id = body.get("customer_id") or None
    customer_tier_raw = (body.get("customer_tier") or "bronze")
    customer_tier = str(customer_tier_raw).strip().lower()
    if customer_tier not in KNOWN_TIERS:
        customer_tier = "bronze"

    # Customer location (city / country / region) plus the client-side
    # simulated network RTT, set by the European load generator. These
    # are *trusted-input* fields in a single-tenant demo: the only path
    # to /process is the in-cluster api-gateway, which is itself the
    # only writer of these keys. We still sanitise so a malformed payload
    # cannot inflate metric cardinality (long opaque strings) or violate
    # the ISO-3166-1 alpha-2 / float invariants downstream dashboards
    # rely on (codeguard-0-input-validation-injection: positive shape
    # checks at every trust boundary, even for first-party callers).
    def _coerce_short_str(value: Any, max_len: int = 32) -> str | None:
        if value is None:
            return None
        s = str(value).strip().lower()
        if not s:
            return None
        return s[:max_len]

    def _coerce_country(value: Any) -> str | None:
        if value is None:
            return None
        s = str(value).strip().upper()
        if len(s) != 2 or not s.isalpha():
            return None
        return s

    def _coerce_lat_lon(value: Any, lo: float, hi: float) -> float | None:
        if value is None or value == "":
            return None
        try:
            f = float(value)
        except (TypeError, ValueError):
            return None
        if f < lo or f > hi:
            return None
        return f

    customer_location = _coerce_short_str(body.get("customer_location"))
    customer_country = _coerce_country(body.get("customer_country"))
    customer_region = _coerce_short_str(body.get("customer_region"))
    customer_lat = _coerce_lat_lon(body.get("customer_lat"), -90.0, 90.0)
    customer_lon = _coerce_lat_lon(body.get("customer_lon"), -180.0, 180.0)
    # customer_home_country = where the bank account lives. Differs from
    # customer_country only when the user is roaming - tagged as a
    # boolean so the fraud-detection panels can pivot on a single
    # high-cardinality-safe attribute (payment.roaming = true / false).
    customer_home_country = _coerce_country(body.get("customer_home_country"))
    payment_roaming = bool(body.get("payment_roaming") or False)
    try:
        network_latency_ms_simulated = max(
            0.0, float(body.get("network_latency_ms_simulated") or 0.0)
        )
    except (TypeError, ValueError):
        network_latency_ms_simulated = 0.0

    span = trace.get_current_span()
    if span is not None and span.is_recording():
        span.set_attribute("payment.id", payment_id)
        span.set_attribute("payment.scenario", scenario)
        span.set_attribute("payment.amount_minor_units", amount_minor_units)
        span.set_attribute("service.tier", SERVICE_TIER)
        span.set_attribute("customer.tier", customer_tier)
        if customer_id:
            span.set_attribute("customer.id", str(customer_id))
        if customer_location:
            span.set_attribute("customer.location", customer_location)
        if customer_country:
            span.set_attribute("customer.country", customer_country)
        if customer_region:
            span.set_attribute("customer.region", customer_region)
        if customer_lat is not None:
            span.set_attribute("customer.lat", customer_lat)
        if customer_lon is not None:
            span.set_attribute("customer.lon", customer_lon)
        if customer_home_country:
            span.set_attribute("customer.home_country", customer_home_country)
        span.set_attribute("payment.roaming", payment_roaming)
        if network_latency_ms_simulated > 0.0:
            span.set_attribute(
                "network.latency_ms_simulated", network_latency_ms_simulated
            )
        if scheme:
            span.set_attribute("payment.scheme", scheme)
        if amount_bucket:
            span.set_attribute("payment.amount_bucket", amount_bucket)
        if currency:
            span.set_attribute("payment.currency", currency)
        if channel:
            span.set_attribute("payment.channel", channel)
        if country_pair:
            span.set_attribute("payment.country_pair", country_pair)
        if originator_country:
            span.set_attribute("payment.originator_country", originator_country)
        if beneficiary_country:
            span.set_attribute("payment.beneficiary_country", beneficiary_country)

    # Tier-aware throttle. Only the gateway tier honours TIER_THROTTLE_PROB so
    # a single Bronze 3% setting doesn't compound across the call chain. The
    # 429 short-circuits everything below: no downstream calls, no Kafka
    # publish, no DB writes - exactly what a real edge throttle would do.
    if SERVICE_TIER == "gateway":
        throttle_prob = TIER_THROTTLE_PROB.get(customer_tier, 0.0)
        if throttle_prob > 0.0 and random.random() < throttle_prob:
            if span is not None and span.is_recording():
                span.set_attribute("payment.throttled", True)
                span.set_attribute("error", True)
                span.set_attribute("error.type", "throttled")
            log.warning(
                "throttled customer_tier=%s customer_id=%s payment_id=%s scheme=%s",
                customer_tier,
                customer_id or "-",
                payment_id,
                scheme,
            )
            if emit_payment_audit is not None:
                emit_payment_audit(
                    payment_id=payment_id,
                    customer_id=customer_id,
                    customer_tier=customer_tier,
                    scheme=scheme,
                    amount_minor_units=amount_minor_units,
                    currency=currency,
                    decision="throttled",
                    decline_reason="tier_throttle",
                    channel=channel,
                )
            return (
                jsonify(
                    {
                        "service": SERVICE_NAME,
                        "payment_id": payment_id,
                        "customer_tier": customer_tier,
                        "error": "throttled",
                    }
                ),
                429,
            )

    # --- Cache lookup (sanctions / fraud features). On hit we skip the
    # tail-latency sleep so the upstream chain sees a fast cached path. On
    # miss we fall through to the normal work + tail-latency code path.
    cache_hit = False
    if CACHE_ENABLED:
        cache_hit = _cache_lookup(f"{CACHE_KEY_NAMESPACE}:{payment_id}")
        if span is not None and span.is_recording():
            span.set_attribute("cache.hit", cache_hit)
            span.set_attribute("cache.namespace", CACHE_KEY_NAMESPACE)

    # Tier-aware fraud fast-path. Independent of the actual cache hit; the
    # business story is "Gold customers go through a curated low-friction
    # screening pipeline, Bronze customers always hit the full kernel". Only
    # honoured on services that actually run the fraud kernel (i.e.
    # fraud-detection-service via FRAUD_FEATURE_EXTRACTOR_ENABLED), which keeps
    # the speed-up from spuriously appearing on unrelated nodes.
    fraud_fast_path = False
    if FRAUD_FEATURE_EXTRACTOR_ENABLED and not cache_hit:
        fast_path_prob = TIER_FRAUD_FAST_PATH_PROB.get(customer_tier, 0.0)
        if fast_path_prob > 0.0 and random.random() < fast_path_prob:
            fraud_fast_path = True
            if span is not None and span.is_recording():
                span.set_attribute("payment.tier_fast_path", True)

    # Fraud feature extraction kernel. Off everywhere except
    # fraud-detection-service. When enabled, runs the linear fingerprint
    # by default; flipping CPU_REGRESSION_ENABLED swaps in the quadratic
    # kernel that drives the AlwaysOn Profiling diff demo.
    #
    # Intentionally NOT gated on cache_hit: in production the cache stores
    # historical feature vectors, but the live drift / freshness
    # fingerprint is recomputed on every request - that's the kind of
    # always-on CPU work where a quadratic regression hurts most. The
    # tier fast-path bypass IS honoured here, however - that's the whole
    # point of the Gold tier story.
    if FRAUD_FEATURE_EXTRACTOR_ENABLED and not fraud_fast_path:
        _compute_fraud_features(payment_id)

    work_ms, tail_injected = _simulate_local_work(force_skip_tail=cache_hit or fraud_fast_path)
    if tail_injected and span is not None and span.is_recording():
        span.set_attribute("payment.tail_latency", True)

    # Location-conditional degradation (Spain / ES screening provider story).
    # No-op unless armed via SLOW_LOCATION_* env on this service. Returns a 5xx
    # short-circuit (with a recorded root-cause exception) for a portion of the
    # matching region's payments; the rest just run slow.
    loc_resp = _maybe_inject_location_degradation(customer_country, payment_id, span)
    if loc_resp is not None:
        return loc_resp

    downstreams = _select_downstreams()
    downstream_results: list[dict[str, Any]] = []
    downstream_errors = 0

    if downstreams:
        # Forward the full set of business fields so downstream spans can also
        # tag their data — Tag Spotlight then works at every tier.
        fwd = {
            "payment_id": payment_id,
            "scenario": scenario,
            "amount_minor_units": amount_minor_units,
            "scheme": scheme,
            "amount_bucket": amount_bucket,
            "currency": currency,
            "channel": channel,
            "country_pair": country_pair,
            "originator_country": originator_country,
            "beneficiary_country": beneficiary_country,
            "customer_id": customer_id,
            "customer_tier": customer_tier,
            "customer_location": customer_location,
            "customer_country": customer_country,
            "customer_region": customer_region,
            "customer_lat": customer_lat,
            "customer_lon": customer_lon,
            "customer_home_country": customer_home_country,
            "payment_roaming": payment_roaming,
            "network_latency_ms_simulated": network_latency_ms_simulated,
            "from": SERVICE_NAME,
        }
        with ThreadPoolExecutor(max_workers=MAX_FANOUT_WORKERS) as pool:
            futures = [pool.submit(_call_downstream, svc, fwd) for svc in downstreams]
            for fut in as_completed(futures):
                result = fut.result()
                downstream_results.append(result)
                if not result["ok"]:
                    downstream_errors += 1

    # Apply the optional per-scheme error multiplier so we can light up only a
    # single scheme (e.g. SWIFT) rather than the whole topology.
    effective_error_rate = ERROR_RATE
    if scheme and scheme in SCHEME_ERROR_MULTIPLIERS:
        effective_error_rate = min(1.0, ERROR_RATE * SCHEME_ERROR_MULTIPLIERS[scheme])

    if random.random() < effective_error_rate:
        if span is not None and span.is_recording():
            span.set_attribute("error", True)
            span.set_attribute("error.type", "simulated")
        log.error(
            "simulated_error payment_id=%s scenario=%s scheme=%s", payment_id, scenario, scheme,
        )
        if SERVICE_TIER == "gateway" and emit_payment_audit is not None:
            emit_payment_audit(
                payment_id=payment_id,
                customer_id=customer_id,
                customer_tier=customer_tier,
                scheme=scheme,
                amount_minor_units=amount_minor_units,
                currency=currency,
                decision="rejected",
                decline_reason="simulated",
                channel=channel,
            )
        return (
            jsonify(
                {
                    "service": SERVICE_NAME,
                    "payment_id": payment_id,
                    "error": "simulated",
                }
            ),
            500,
        )

    # Fire-and-forget Kafka publish for services configured as producers
    # (typically payment-initiation-service after a successful fan-out).
    if KAFKA_PRODUCER_ENABLED:
        _publish_settlement(
            payment_id,
            {
                "scheme": scheme,
                "amount_minor_units": amount_minor_units,
                "currency": currency,
                "country_pair": country_pair,
                "originator_country": originator_country,
                "beneficiary_country": beneficiary_country,
                "channel": channel,
                "amount_bucket": amount_bucket,
                "scenario": scenario,
            },
        )

    log.info(
        "processed payment_id=%s scenario=%s scheme=%s customer_tier=%s customer_id=%s "
        "work_ms=%.1f tail=%s cache_hit=%s fast_path=%s downstreams=%d errors=%d",
        payment_id,
        scenario,
        scheme,
        customer_tier,
        customer_id or "-",
        work_ms,
        tail_injected,
        cache_hit,
        fraud_fast_path,
        len(downstreams),
        downstream_errors,
    )
    # Record this payment into the shared ring buffer so subsequent GET
    # /recent and GET /status/<id> calls have something real to return.
    # Only the gateway tier holds the canonical view; deeper services
    # would otherwise duplicate the same data and the buffer wouldn't
    # reflect "what the customer submitted at the edge".
    if SERVICE_TIER == "gateway":
        active_span = trace.get_current_span()
        ctx = active_span.get_span_context() if active_span is not None else None
        trace_id_hex = (
            format(ctx.trace_id, "032x") if ctx is not None and ctx.is_valid else None
        )
        _record_recent(
            {
                "payment_id": payment_id,
                "scheme": scheme,
                "amount_minor_units": amount_minor_units,
                "currency": currency,
                "channel": channel,
                "customer_id": customer_id,
                "customer_tier": customer_tier,
                "scenario": scenario,
                "status": "accepted" if downstream_errors == 0 else "partial",
                "downstream_errors": downstream_errors,
                "submitted_at": time.time(),
                "trace_id": trace_id_hex,
            }
        )

        # Synthetic banking audit record. Only emitted from the gateway
        # tier so we don't double-count the same payment from each
        # service in the chain. The emitter is the right seam for this:
        # the gateway has the canonical decision (accepted vs partial)
        # plus the customer context the SPA sent in.
        if emit_payment_audit is not None:
            decision = "accepted" if downstream_errors == 0 else "review"
            decline_reason = "downstream_error" if downstream_errors > 0 else None
            emit_payment_audit(
                payment_id=payment_id,
                customer_id=customer_id,
                customer_tier=customer_tier,
                scheme=scheme,
                amount_minor_units=amount_minor_units,
                currency=currency,
                decision=decision,
                decline_reason=decline_reason,
                sanctions_hit=False,
                fraud_score=None,
                channel=channel,
            )

    return jsonify(
        {
            "service": SERVICE_NAME,
            "payment_id": payment_id,
            "scenario": scenario,
            "scheme": scheme,
            "customer_tier": customer_tier,
            "work_ms": round(work_ms, 1),
            "tail_latency": tail_injected,
            "cache_hit": cache_hit,
            "tier_fast_path": fraud_fast_path,
            "downstream_results": downstream_results,
            # Top-level "status" is the gateway's view of the payment
            # outcome. Same value the audit record + recent buffer use
            # (line 1519 / 1532). Three consumers depend on this field
            # and all three were silently getting `undefined` before:
            #   1. The SPA (frontend/src/api.ts PaymentResponse.status)
            #      reads it to render the success-page StatusPill and to
            #      tag the "submit-payment.success" RUM page-action with
            #      payment.server_status -- both were broken until this
            #      key was added.
            #   2. The ThousandEyes TE-04 / TE-05 synthetic test asserts
            #      a contentRegex of `"status":"(accepted|partial)"`; the
            #      missing field made every probe register as a failed
            #      assertion, which drove the Glass Table's "GBP at risk"
            #      and "synthetic outage" panels to nonsensical readings.
            #   3. The audit-trail decision (`accepted` / `review`) is
            #      derived from the same `downstream_errors` count and
            #      will now match this top-level status exactly.
            "status": "accepted" if downstream_errors == 0 else "partial",
            "downstream_errors": downstream_errors,
        }
    )


def _read_lookup_payload(operation: str, payment_id: str | None = None) -> dict[str, Any]:
    """Small payload posted to downstream services from the read endpoints.

    Mirrors the shape of a real /process call so downstream span
    attributes (payment.id, customer.tier, etc.) are still populated.
    Marked with read_api.operation so dashboards can split read vs.
    write traffic and the demo presenter can show "GET /recent fans
    out into reporting-service" cleanly.
    """
    return {
        "payment_id": payment_id or f"read-{uuid.uuid4()}",
        "scenario": f"read.{operation}",
        "amount_minor_units": 0,
        "scheme": "FPS",
        "currency": "GBP",
        "channel": "web",
        "customer_id": "read-api",
        "customer_tier": "bronze",
        "from": SERVICE_NAME,
        "read_api.operation": operation,
    }


@app.get("/recent")
def recent() -> Any:
    """Return a snapshot of the most-recently processed payments.

    The SPA's Recent page hits this on load (via /api/recent at the public
    proxy). Each call produces a single api-gateway server span, plus
    optional downstream client spans if READ_API_RECENT_DOWNSTREAMS is
    populated - which is exactly what we want for the RUM->APM pivot
    (the fetch span the browser produces lines up trace-id with the
    server span here, and Splunk RUM draws the "View APM trace" link
    on the back of the Server-Timing response header that splunk-py-trace
    injects automatically).
    """
    try:
        limit = max(1, min(100, int(request.args.get("limit", "25"))))
    except (TypeError, ValueError):
        limit = 25

    span = trace.get_current_span()
    if span is not None and span.is_recording():
        span.set_attribute("read_api.operation", "recent")
        span.set_attribute("read_api.limit", limit)

    items = _list_recent(limit)

    if span is not None and span.is_recording():
        span.set_attribute("read_api.result_count", len(items))
        span.set_attribute(
            "read_api.backend",
            "redis" if _read_api_redis is not None else "in-process",
        )

    if READ_API_RECENT_DOWNSTREAMS:
        payload = _read_lookup_payload("recent")
        with ThreadPoolExecutor(max_workers=max(1, len(READ_API_RECENT_DOWNSTREAMS))) as pool:
            futures = [
                pool.submit(_call_downstream, svc, payload)
                for svc in READ_API_RECENT_DOWNSTREAMS
            ]
            for fut in as_completed(futures):
                # Drain results to keep the trace tidy; we don't need them on
                # the response, the spans are the value here.
                fut.result()

    return jsonify(
        {
            "service": SERVICE_NAME,
            "count": len(items),
            "items": items,
        }
    )


@app.get("/status/<payment_id>")
def status(payment_id: str) -> Any:
    """Look up a single payment by id.

    If the id matches an entry in the ring buffer we return the recorded
    state; if not, we synthesize a "not_found" response (still 200 so the
    SPA can render a friendly message instead of an exception). When
    READ_API_STATUS_DOWNSTREAMS is set, we also POST /process to those
    services so the resulting APM trace is multi-service - matching the
    "gateway -> payment-status-service" story the demo wants to tell.
    """
    span = trace.get_current_span()
    if span is not None and span.is_recording():
        span.set_attribute("read_api.operation", "status")
        span.set_attribute("payment.id", payment_id)

    match = _find_recent(payment_id)

    if span is not None and span.is_recording():
        span.set_attribute("read_api.found", match is not None)
        span.set_attribute(
            "read_api.backend",
            "redis" if _read_api_redis is not None else "in-process",
        )

    if READ_API_STATUS_DOWNSTREAMS:
        payload = _read_lookup_payload("status", payment_id=payment_id)
        with ThreadPoolExecutor(max_workers=max(1, len(READ_API_STATUS_DOWNSTREAMS))) as pool:
            futures = [
                pool.submit(_call_downstream, svc, payload)
                for svc in READ_API_STATUS_DOWNSTREAMS
            ]
            for fut in as_completed(futures):
                fut.result()

    if match is None:
        return jsonify(
            {
                "service": SERVICE_NAME,
                "payment_id": payment_id,
                "status": "not_found",
                "message": "no recent record for this payment id on this gateway pod",
            }
        )

    # Return a copy so we don't accidentally hand a reference to the live
    # ring buffer entry to the JSON serializer.
    return jsonify({"service": SERVICE_NAME, **match})


# Start the Kafka consumer thread (no-op unless KAFKA_CONSUMER_ENABLED). Done
# after all helpers are defined so the consumer thread can resolve them.
_ensure_consumer_started()


if __name__ == "__main__":
    # Used for local dev only. In-cluster we run under gunicorn via entrypoint.sh.
    port = int(os.environ.get("PORT", "8080"))
    app.run(host="0.0.0.0", port=port)
