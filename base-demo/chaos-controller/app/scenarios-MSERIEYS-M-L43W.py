"""Chaos scenario catalog + inject/clear implementations.

Each scenario exposes:

    inject(params: dict | None) -> dict     # describes the action taken
    clear() -> dict                          # reverts to baseline
    status() -> {"state": "armed"|"clear"|"unknown", "observed": dict}

Scenario IDs are an allow-list - the HTTP dispatcher rejects anything
not in ``CATALOG`` with a 404 (codeguard-0-input-validation-injection:
positive allow-list at the trust boundary). The same allow-list is
echoed back to the SPA so the dashboard never shows a scenario the
controller cannot execute.

Baselines mirror the values set by [helm/natwest-payments/values.yaml]
and [scripts/incident.sh]; if the chart's defaults change, update the
``BASELINE_*`` constants here too. The cost of drift is a stale
"armed" indicator on the dashboard, not a runtime error.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field
from typing import Any, Callable

from . import k8s
from .orchestrators import runner as _meltdown_runner

LOG = logging.getLogger("chaos-controller.scenarios")


# ---------------------------------------------------------------------------
# Reserved params key the dispatcher uses to plumb the X-Operator header
# into orchestrator scenarios without breaking the existing single-arg
# inject(params) shape. Regular Scenario._inject_* functions ignore the
# key; only the orchestrator shims read it. See main.py's inject() route
# for the dispatcher-side write.
# ---------------------------------------------------------------------------

ACTOR_PARAM_KEY = "__actor"


def _extract_actor(params: dict[str, Any] | None, default: str = "ops-dashboard") -> str:
    if not isinstance(params, dict):
        return default
    raw = params.pop(ACTOR_PARAM_KEY, None)
    if raw is None or not isinstance(raw, str):
        return default
    cleaned = raw.strip()
    return cleaned[:64] if cleaned else default


# ---------------------------------------------------------------------------
# Baselines. These must match helm/natwest-payments/values.yaml so that
# `clear()` restores the values the chart originally applied.
# ---------------------------------------------------------------------------

BASELINE_FRAUD_ERROR_RATE = "0.02"
BASELINE_SWIFT_ERROR_RATE = "0.05"
BASELINE_SANCTIONS_CACHE_HIT_RATE = "0.97"
BASELINE_DB_LATENCY_MS = "0"
BASELINE_CPU_REGRESSION = "false"
BASELINE_KAFKA_PRODUCER_ENABLED = "true"
BASELINE_SANCTIONS_CACHE_ENABLED = "true"
BASELINE_TAIL_LATENCY_RATE = "0.0"
BASELINE_PAYMENT_STATUS_LATENCY_MEAN = "10"
# Matches helm api-gateway.downstreamTimeoutS (12s) so clear() after
# gateway-timeout-squeeze does not tighten the gateway below the chart.
BASELINE_GATEWAY_DOWNSTREAM_TIMEOUT_S = "12.0"
BASELINE_FRAUD_SCHEME_MULTIPLIERS = "SWIFT:3,CHAPS:2"
BASELINE_TIER_THROTTLE_PROB = "bronze:0.0,silver:0.0,gold:0.0"
BASELINE_TIER_FRAUD_FAST_PATH_PROB = "bronze:0.0,silver:0.2,gold:0.6"
# Empty string => use the baked-in LOCATIONS table in
# traffic-generator/generate.py (Madrid: 450 +/- 120 ms). madrid-network-
# degradation injects an override that escalates Madrid to a full-blown
# incident; clear() returns to "" so the baseline takes over again.
BASELINE_LOCATION_LATENCY_PROFILES = ""
# traffic-generator/deployment.yaml steady-state load shape.
BASELINE_TRAFFIC_RPS = "25"
BASELINE_TRAFFIC_RPS_SCHEDULE = (
    '[{"hour":0,"rps":3},{"hour":7,"rps":10},{"hour":9,"rps":40},'
    '{"hour":12,"rps":30},{"hour":13,"rps":30},{"hour":15,"rps":40},'
    '{"hour":17,"rps":50},{"hour":20,"rps":15},{"hour":23,"rps":3}]'
)
# Steady-state replica counts from helm/natwest-payments/values.yaml. Used by
# apm-topology-repair and kill-service restore so a demo incident cannot
# permanently strand api-gateway on 1 replica (which orphans edges and
# causes traffic-generator to look "floating" under load).
STEADY_REPLICA_COUNTS: dict[str, int] = {
    "api-gateway": 2,
    "routing-service": 2,
    "payment-initiation-service": 3,
    "payment-validation-service": 2,
}

# Splunk APM draws infrastructure glyphs from trace peer.service + db.system /
# messaging.system. This mapping must match helm deployment.yaml and keeps
# JDBC/redis/kafka client spans off long FQDN node labels.
APM_PEER_SERVICE_MAPPING = (
    "postgres.natwest.svc.cluster.local=postgres,"
    "kafka.natwest.svc.cluster.local=kafka,"
    "redis.natwest.svc.cluster.local=redis"
)

STEADY_STATE_TRAFFIC_RPS = "12"

DEFAULT_FRAUD_ERROR_RATE = "0.20"
DEFAULT_SWIFT_ERROR_RATE = "0.30"
DEFAULT_SANCTIONS_COLD_CACHE_HIT_RATE = "0.40"
DEFAULT_DB_LATENCY_MS = "200"
DEFAULT_TAIL_LATENCY_STORM_RATE = "0.10"
DEFAULT_LATENCY_CREEP_MEAN = "200"
DEFAULT_GATEWAY_TIMEOUT_S = "0.5"
DEFAULT_FRAUD_SCHEME_OUTAGE = "SWIFT:5"
DEFAULT_TIER_THROTTLE_RATE = "0.30"
# Madrid degraded profile: 2.0 s mean, 0.4 s stddev. Big enough that the
# customer.location=madrid p95 panel jumps from ~600 ms baseline to ~2.5 s
# within one minute, but still under the gateway's 15 s timeout so spans
# complete normally (no client-side error inflation).
DEFAULT_MADRID_DEGRADED_PROFILE = "madrid:2000/400"

# Allowed customer tiers - mirrors scripts/incident.sh KNOWN_TIERS.
KNOWN_TIERS = ("bronze", "silver", "gold")


def _killable_services() -> list[str]:
    """Allow-list of deployments the ``kill-service`` scenario can scale to 0.

    Sourced from the ``KILLABLE_SERVICES`` env var (comma-separated),
    which is set by the Helm chart from ``chaosController.killable_services``.
    Defaults to a safe set if the env var is missing.
    """
    raw = os.environ.get("KILLABLE_SERVICES", "").strip()
    if not raw:
        return [
            "api-gateway",
            "fraud-detection-service",
            "payment-status-service",
            "sanctions-aml-service",
            "swift-network",
        ]
    return [s.strip() for s in raw.split(",") if s.strip()]


# ---------------------------------------------------------------------------
# Status helpers.
# ---------------------------------------------------------------------------


def _status_from_env(
    deployment: str,
    key: str,
    armed_when: Callable[[str], bool],
    baseline: str,
) -> dict[str, Any]:
    observed = k8s.current_env(deployment, [key])
    if not observed:
        return {"state": "unknown", "observed": {}}
    current = observed.get(key, "")
    if current == "":
        state = "clear"
    elif armed_when(current):
        state = "armed"
    else:
        state = "clear"
    return {
        "state": state,
        "observed": {key: current, "baseline": baseline},
    }


def _status_scale_to_zero(deployment: str) -> dict[str, Any]:
    replicas = k8s.current_replicas(deployment)
    if replicas is None:
        return {"state": "unknown", "observed": {}}
    return {
        "state": "armed" if replicas == 0 else "clear",
        "observed": {"replicas": replicas, "deployment": deployment},
    }


def _float_eq(a: str, b: str) -> bool:
    try:
        return abs(float(a) - float(b)) < 1e-9
    except (TypeError, ValueError):
        return False


# ---------------------------------------------------------------------------
# A. App errors
# ---------------------------------------------------------------------------


def _inject_bad_deploy_fraud(_params: dict[str, Any] | None) -> dict[str, Any]:
    return k8s.set_env(
        "fraud-detection-service", {"ERROR_RATE": DEFAULT_FRAUD_ERROR_RATE}
    )


def _clear_bad_deploy_fraud() -> dict[str, Any]:
    return k8s.set_env(
        "fraud-detection-service", {"ERROR_RATE": BASELINE_FRAUD_ERROR_RATE}
    )


def _status_bad_deploy_fraud() -> dict[str, Any]:
    return _status_from_env(
        "fraud-detection-service",
        "ERROR_RATE",
        lambda v: not _float_eq(v, BASELINE_FRAUD_ERROR_RATE) and not _float_eq(v, "0"),
        BASELINE_FRAUD_ERROR_RATE,
    )


def _inject_swift_counterparty_flap(_params: dict[str, Any] | None) -> dict[str, Any]:
    return k8s.set_env("swift-network", {"ERROR_RATE": DEFAULT_SWIFT_ERROR_RATE})


def _clear_swift_counterparty_flap() -> dict[str, Any]:
    return k8s.set_env("swift-network", {"ERROR_RATE": BASELINE_SWIFT_ERROR_RATE})


def _status_swift_counterparty_flap() -> dict[str, Any]:
    return _status_from_env(
        "swift-network",
        "ERROR_RATE",
        lambda v: not _float_eq(v, BASELINE_SWIFT_ERROR_RATE) and not _float_eq(v, "0"),
        BASELINE_SWIFT_ERROR_RATE,
    )


def _inject_swift_scheme_outage(_params: dict[str, Any] | None) -> dict[str, Any]:
    return k8s.set_env(
        "fraud-detection-service",
        {"SCHEME_ERROR_MULTIPLIERS": DEFAULT_FRAUD_SCHEME_OUTAGE},
    )


def _clear_swift_scheme_outage() -> dict[str, Any]:
    return k8s.set_env(
        "fraud-detection-service",
        {"SCHEME_ERROR_MULTIPLIERS": BASELINE_FRAUD_SCHEME_MULTIPLIERS},
    )


def _status_swift_scheme_outage() -> dict[str, Any]:
    return _status_from_env(
        "fraud-detection-service",
        "SCHEME_ERROR_MULTIPLIERS",
        lambda v: "SWIFT:" in v.upper() and v != BASELINE_FRAUD_SCHEME_MULTIPLIERS,
        BASELINE_FRAUD_SCHEME_MULTIPLIERS,
    )


def _inject_settlement_producer_off(_params: dict[str, Any] | None) -> dict[str, Any]:
    return k8s.set_env(
        "payment-initiation-service", {"KAFKA_PRODUCER_ENABLED": "false"}
    )


def _clear_settlement_producer_off() -> dict[str, Any]:
    return k8s.set_env(
        "payment-initiation-service",
        {"KAFKA_PRODUCER_ENABLED": BASELINE_KAFKA_PRODUCER_ENABLED},
    )


def _status_settlement_producer_off() -> dict[str, Any]:
    return _status_from_env(
        "payment-initiation-service",
        "KAFKA_PRODUCER_ENABLED",
        lambda v: v.strip().lower() in {"false", "0", "no", "off"},
        BASELINE_KAFKA_PRODUCER_ENABLED,
    )


def _inject_sanctions_cache_disabled(_params: dict[str, Any] | None) -> dict[str, Any]:
    return k8s.set_env("sanctions-aml-service", {"CACHE_ENABLED": "false"})


def _clear_sanctions_cache_disabled() -> dict[str, Any]:
    return k8s.set_env(
        "sanctions-aml-service",
        {"CACHE_ENABLED": BASELINE_SANCTIONS_CACHE_ENABLED},
    )


def _status_sanctions_cache_disabled() -> dict[str, Any]:
    return _status_from_env(
        "sanctions-aml-service",
        "CACHE_ENABLED",
        lambda v: v.strip().lower() in {"false", "0", "no", "off"},
        BASELINE_SANCTIONS_CACHE_ENABLED,
    )


# ---------------------------------------------------------------------------
# B. Latency
# ---------------------------------------------------------------------------


def _inject_db_slow(_params: dict[str, Any] | None) -> dict[str, Any]:
    return k8s.set_env("ledger-service", {"DB_LATENCY_MS": DEFAULT_DB_LATENCY_MS})


def _clear_db_slow() -> dict[str, Any]:
    return k8s.set_env("ledger-service", {"DB_LATENCY_MS": BASELINE_DB_LATENCY_MS})


def _status_db_slow() -> dict[str, Any]:
    return _status_from_env(
        "ledger-service",
        "DB_LATENCY_MS",
        lambda v: not _float_eq(v, BASELINE_DB_LATENCY_MS),
        BASELINE_DB_LATENCY_MS,
    )


def _inject_fraud_cpu_regression(_params: dict[str, Any] | None) -> dict[str, Any]:
    return k8s.set_env(
        "fraud-detection-service", {"CPU_REGRESSION_ENABLED": "true"}
    )


def _clear_fraud_cpu_regression() -> dict[str, Any]:
    return k8s.set_env(
        "fraud-detection-service",
        {"CPU_REGRESSION_ENABLED": BASELINE_CPU_REGRESSION},
    )


def _status_fraud_cpu_regression() -> dict[str, Any]:
    return _status_from_env(
        "fraud-detection-service",
        "CPU_REGRESSION_ENABLED",
        lambda v: v.strip().lower() in {"true", "1", "yes", "on"},
        BASELINE_CPU_REGRESSION,
    )


def _inject_tail_latency_storm(_params: dict[str, Any] | None) -> dict[str, Any]:
    return k8s.set_env(
        "payment-validation-service",
        {"TAIL_LATENCY_RATE": DEFAULT_TAIL_LATENCY_STORM_RATE},
    )


def _clear_tail_latency_storm() -> dict[str, Any]:
    return k8s.set_env(
        "payment-validation-service",
        {"TAIL_LATENCY_RATE": BASELINE_TAIL_LATENCY_RATE},
    )


def _status_tail_latency_storm() -> dict[str, Any]:
    return _status_from_env(
        "payment-validation-service",
        "TAIL_LATENCY_RATE",
        lambda v: not _float_eq(v, BASELINE_TAIL_LATENCY_RATE) and not _float_eq(v, "0"),
        BASELINE_TAIL_LATENCY_RATE,
    )


def _inject_latency_creep(_params: dict[str, Any] | None) -> dict[str, Any]:
    return k8s.set_env(
        "payment-status-service",
        {"LATENCY_MS_MEAN": DEFAULT_LATENCY_CREEP_MEAN},
    )


def _clear_latency_creep() -> dict[str, Any]:
    return k8s.set_env(
        "payment-status-service",
        {"LATENCY_MS_MEAN": BASELINE_PAYMENT_STATUS_LATENCY_MEAN},
    )


def _status_latency_creep() -> dict[str, Any]:
    return _status_from_env(
        "payment-status-service",
        "LATENCY_MS_MEAN",
        lambda v: not _float_eq(v, BASELINE_PAYMENT_STATUS_LATENCY_MEAN),
        BASELINE_PAYMENT_STATUS_LATENCY_MEAN,
    )


def _inject_gateway_timeout_squeeze(_params: dict[str, Any] | None) -> dict[str, Any]:
    return k8s.set_env(
        "api-gateway",
        {"DOWNSTREAM_TIMEOUT_S": DEFAULT_GATEWAY_TIMEOUT_S},
    )


def _clear_gateway_timeout_squeeze() -> dict[str, Any]:
    return k8s.set_env(
        "api-gateway",
        {"DOWNSTREAM_TIMEOUT_S": BASELINE_GATEWAY_DOWNSTREAM_TIMEOUT_S},
    )


def _status_gateway_timeout_squeeze() -> dict[str, Any]:
    return _status_from_env(
        "api-gateway",
        "DOWNSTREAM_TIMEOUT_S",
        lambda v: not _float_eq(v, BASELINE_GATEWAY_DOWNSTREAM_TIMEOUT_S),
        BASELINE_GATEWAY_DOWNSTREAM_TIMEOUT_S,
    )


def _inject_madrid_degradation(params: dict[str, Any] | None) -> dict[str, Any]:
    """Bump the Madrid RTT profile on the traffic-generator.

    Optional params:
      mean_ms   - gaussian mean for the RTT sleep (default 2000)
      stddev_ms - gaussian stddev for the RTT sleep (default 400)

    The grammar matches traffic-generator/generate.py::_parse_location_latency_profiles:
    "madrid:<mean>/<stddev>". We deliberately leave the other cities
    untouched so the resulting "p95 by customer.location" panel shows
    only Madrid moving - the story is "the Spanish link is degraded,
    everywhere else is fine".
    """
    p = params or {}
    try:
        mean_ms = float(p.get("mean_ms", 2000.0))
        stddev_ms = float(p.get("stddev_ms", 400.0))
    except (TypeError, ValueError) as exc:
        raise ValueError(
            f"madrid-network-degradation requires numeric mean_ms/stddev_ms, got {p!r}"
        ) from exc
    # Bound the values so a typo can't sleep for minutes per request.
    if not (50.0 <= mean_ms <= 10_000.0):
        raise ValueError("madrid-network-degradation mean_ms must be in [50, 10000]")
    if not (0.0 <= stddev_ms <= 5_000.0):
        raise ValueError("madrid-network-degradation stddev_ms must be in [0, 5000]")
    profile = f"madrid:{mean_ms:.0f}/{stddev_ms:.0f}"
    return k8s.set_env("traffic-generator", {"LOCATION_LATENCY_PROFILES": profile})


def _clear_madrid_degradation() -> dict[str, Any]:
    return k8s.set_env(
        "traffic-generator",
        {"LOCATION_LATENCY_PROFILES": BASELINE_LOCATION_LATENCY_PROFILES},
    )


def _status_madrid_degradation() -> dict[str, Any]:
    return _status_from_env(
        "traffic-generator",
        "LOCATION_LATENCY_PROFILES",
        lambda v: "madrid:" in v.lower(),
        BASELINE_LOCATION_LATENCY_PROFILES,
    )


def _inject_traffic_steady_state(_params: dict[str, Any] | None) -> dict[str, Any]:
    """Lower synthetic load so the payment chain can drain queues after chaos."""
    return k8s.set_env(
        "traffic-generator",
        {
            "RPS": STEADY_STATE_TRAFFIC_RPS,
            "RPS_SCHEDULE": "",
        },
    )


def _clear_traffic_steady_state() -> dict[str, Any]:
    return k8s.set_env(
        "traffic-generator",
        {
            "RPS": BASELINE_TRAFFIC_RPS,
            "RPS_SCHEDULE": BASELINE_TRAFFIC_RPS_SCHEDULE,
        },
    )


def _status_traffic_steady_state() -> dict[str, Any]:
    observed = k8s.current_env(
        "traffic-generator", ["RPS", "RPS_SCHEDULE"]
    )
    if not observed:
        return {"state": "unknown", "observed": {}}
    rps = observed.get("RPS", "")
    schedule = observed.get("RPS_SCHEDULE", "")
    armed = rps == STEADY_STATE_TRAFFIC_RPS and schedule.strip() == ""
    return {
        "state": "armed" if armed else "clear",
        "observed": {
            "RPS": rps,
            "RPS_SCHEDULE": schedule,
            "baseline_rps": BASELINE_TRAFFIC_RPS,
        },
    }


def _restartable_services() -> list[str]:
    raw = os.environ.get("RESTARTABLE_SERVICES", "").strip()
    if not raw:
        return [
            "api-gateway",
            "payment-initiation-service",
            "routing-service",
            "payment-validation-service",
            "traffic-generator",
        ]
    return [s.strip() for s in raw.split(",") if s.strip()]


def _inject_pod_restart_service(params: dict[str, Any] | None) -> dict[str, Any]:
    service_raw = (params or {}).get("service", "api-gateway")
    service = str(service_raw).strip()
    restartable = _restartable_services()
    if service not in restartable:
        raise ValueError(
            f"pod-restart-service requires params.service in {restartable}, "
            f"got {service_raw!r}"
        )
    return k8s.delete_random_pod(f"app.kubernetes.io/name={service}")


def _clear_pod_restart_service() -> dict[str, Any]:
    return {"transient": True}


def _status_pod_restart_service() -> dict[str, Any]:
    return {
        "state": "clear",
        "observed": {
            "restartable": _restartable_services(),
            "note": "transient action; no persistent state",
        },
    }


def _repair_apm_topology() -> dict[str, Any]:
    """Idempotent repair of Splunk APM service-map wiring.

    Re-applies the steady-state env vars and replica counts that keep every
    node connected (traffic-generator -> api-gateway, payment-initiation ->
    kafka -> settlement, ledger -> postgres inferred glyph, etc.). Safe to
    call after chaos demos, kill-service incidents, or a payment-meltdown
    arc that left DB_LATENCY_MS armed.
    """
    results: dict[str, Any] = {}

    if k8s.deployment_exists("payment-initiation-service"):
        results["payment_initiation_env"] = k8s.set_env(
            "payment-initiation-service",
            {
                "KAFKA_PEER_SERVICE": "kafka",
                "KAFKA_PRODUCER_ENABLED": BASELINE_KAFKA_PRODUCER_ENABLED,
            },
        )

    if k8s.deployment_exists("ledger-service"):
        results["ledger_env"] = k8s.set_env(
            "ledger-service",
            {
                "DB_LATENCY_MS": BASELINE_DB_LATENCY_MS,
                "OTEL_LOGS_EXPORTER": "otlp",
                "OTEL_INSTRUMENTATION_COMMON_PEER_SERVICE_MAPPING": (
                    APM_PEER_SERVICE_MAPPING
                ),
            },
        )

    if k8s.deployment_exists("api-gateway"):
        results["api_gateway_env"] = k8s.set_env(
            "api-gateway",
            {
                "DOWNSTREAM_TIMEOUT_S": BASELINE_GATEWAY_DOWNSTREAM_TIMEOUT_S,
                "OTEL_INSTRUMENTATION_COMMON_PEER_SERVICE_MAPPING": (
                    APM_PEER_SERVICE_MAPPING
                ),
            },
        )

    for deploy, replicas in STEADY_REPLICA_COUNTS.items():
        if not k8s.deployment_exists(deploy):
            continue
        current = k8s.current_replicas(deploy)
        if current is not None and current != replicas:
            results[f"scale_{deploy}"] = k8s.scale(deploy, replicas)

    if k8s.deployment_exists("traffic-generator"):
        results["traffic_generator_restart"] = k8s.delete_random_pod(
            "app.kubernetes.io/name=traffic-generator"
        )

    return results


def _inject_apm_topology_repair(_params: dict[str, Any] | None) -> dict[str, Any]:
    return _repair_apm_topology()


def _clear_apm_topology_repair() -> dict[str, Any]:
    return _repair_apm_topology()


def _status_apm_topology_repair() -> dict[str, Any]:
    observed: dict[str, Any] = {"steady_replicas": STEADY_REPLICA_COUNTS}
    drift: list[str] = []
    for deploy, want in STEADY_REPLICA_COUNTS.items():
        if not k8s.deployment_exists(deploy):
            continue
        have = k8s.current_replicas(deploy)
        observed[f"replicas_{deploy}"] = have
        if have is not None and have != want:
            drift.append(f"{deploy}={have} (want {want})")
    if k8s.deployment_exists("payment-initiation-service"):
        env = k8s.current_env(
            "payment-initiation-service", ["KAFKA_PEER_SERVICE"]
        )
        observed["KAFKA_PEER_SERVICE"] = env.get("KAFKA_PEER_SERVICE", "")
        if env.get("KAFKA_PEER_SERVICE", "") != "kafka":
            drift.append("KAFKA_PEER_SERVICE!=kafka")
    if k8s.deployment_exists("ledger-service"):
        env = k8s.current_env("ledger-service", ["DB_LATENCY_MS"])
        observed["DB_LATENCY_MS"] = env.get("DB_LATENCY_MS", "")
        if env.get("DB_LATENCY_MS", "") not in ("", "0"):
            drift.append("DB_LATENCY_MS!=0")
    return {
        "state": "armed" if drift else "clear",
        "observed": observed,
        "drift": drift,
    }


# ---------------------------------------------------------------------------
# C. Customer tier
# ---------------------------------------------------------------------------


def _tier_map(active_tier: str, rate: str) -> str:
    """Build a TIER_THROTTLE_PROB string with one tier hot.

    e.g. _tier_map("bronze", "0.30") -> "bronze:0.30,silver:0.0,gold:0.0".
    """
    parts: list[str] = []
    for t in KNOWN_TIERS:
        parts.append(f"{t}:{rate if t == active_tier else '0.0'}")
    return ",".join(parts)


def _inject_tier_throttle(params: dict[str, Any] | None) -> dict[str, Any]:
    tier_raw = (params or {}).get("tier", "")
    tier = str(tier_raw).strip().lower()
    if tier not in KNOWN_TIERS:
        raise ValueError(
            f"tier-throttle requires params.tier in {KNOWN_TIERS}, got {tier_raw!r}"
        )
    rate_raw = (params or {}).get("rate", DEFAULT_TIER_THROTTLE_RATE)
    try:
        rate_f = float(rate_raw)
    except (TypeError, ValueError):
        raise ValueError(f"tier-throttle rate must be numeric, got {rate_raw!r}")
    if not (0.0 <= rate_f <= 1.0):
        raise ValueError("tier-throttle rate must be in [0.0, 1.0]")
    rate = f"{rate_f:.2f}"
    return k8s.set_env(
        "api-gateway", {"TIER_THROTTLE_PROB": _tier_map(tier, rate)}
    )


def _clear_tier_throttle() -> dict[str, Any]:
    return k8s.set_env(
        "api-gateway", {"TIER_THROTTLE_PROB": BASELINE_TIER_THROTTLE_PROB}
    )


def _status_tier_throttle() -> dict[str, Any]:
    return _status_from_env(
        "api-gateway",
        "TIER_THROTTLE_PROB",
        lambda v: v.strip() not in {"", BASELINE_TIER_THROTTLE_PROB}
        and any(
            (not part.endswith(":0.0") and not part.endswith(":0"))
            for part in v.split(",")
        ),
        BASELINE_TIER_THROTTLE_PROB,
    )


def _inject_cache_cold(_params: dict[str, Any] | None) -> dict[str, Any]:
    return k8s.set_env(
        "sanctions-aml-service",
        {"CACHE_HIT_RATE": DEFAULT_SANCTIONS_COLD_CACHE_HIT_RATE},
    )


def _clear_cache_cold() -> dict[str, Any]:
    return k8s.set_env(
        "sanctions-aml-service",
        {"CACHE_HIT_RATE": BASELINE_SANCTIONS_CACHE_HIT_RATE},
    )


def _status_cache_cold() -> dict[str, Any]:
    return _status_from_env(
        "sanctions-aml-service",
        "CACHE_HIT_RATE",
        lambda v: not _float_eq(v, BASELINE_SANCTIONS_CACHE_HIT_RATE),
        BASELINE_SANCTIONS_CACHE_HIT_RATE,
    )


def _inject_gold_fast_path_off(_params: dict[str, Any] | None) -> dict[str, Any]:
    # Gold-only: keep Silver at its 0.2 baseline fast-path bias so only Gold
    # customers feel the slow-path latency hit in ITSI tier KPIs.
    return k8s.set_env(
        "fraud-detection-service",
        {"TIER_FRAUD_FAST_PATH_PROB": "bronze:0.0,silver:0.2,gold:0.0"},
    )


def _clear_gold_fast_path_off() -> dict[str, Any]:
    return k8s.set_env(
        "fraud-detection-service",
        {"TIER_FRAUD_FAST_PATH_PROB": BASELINE_TIER_FRAUD_FAST_PATH_PROB},
    )


def _status_gold_fast_path_off() -> dict[str, Any]:
    return _status_from_env(
        "fraud-detection-service",
        "TIER_FRAUD_FAST_PATH_PROB",
        lambda v: v.strip() == "bronze:0.0,silver:0.2,gold:0.0",
        BASELINE_TIER_FRAUD_FAST_PATH_PROB,
    )


# ---------------------------------------------------------------------------
# D. Infrastructure outages
# ---------------------------------------------------------------------------


# Remember declared replica counts before kill-service scales to 0 so
# clear() can restore api-gateway to 2 (not 1) after a demo incident.
_KILL_PRIOR_REPLICAS: dict[str, int] = {}
_KILL_RESTORE_DEFAULTS: dict[str, int] = {
    "api-gateway": STEADY_REPLICA_COUNTS["api-gateway"],
    "fraud-detection-service": 1,
    "payment-status-service": 1,
    "sanctions-aml-service": 1,
    "swift-network": 1,
}


def _inject_kill_service(params: dict[str, Any] | None) -> dict[str, Any]:
    service_raw = (params or {}).get("service", "")
    service = str(service_raw).strip()
    killable = _killable_services()
    if service not in killable:
        raise ValueError(
            f"kill-service requires params.service in {killable}, got {service_raw!r}"
        )
    before = k8s.current_replicas(service)
    if before is not None and before > 0:
        _KILL_PRIOR_REPLICAS[service] = before
    return k8s.scale(service, 0)


def _clear_kill_service() -> dict[str, Any]:
    results: list[dict[str, Any]] = []
    for svc in _killable_services():
        if not k8s.deployment_exists(svc):
            continue
        replicas = k8s.current_replicas(svc)
        if replicas == 0:
            restore = _KILL_PRIOR_REPLICAS.pop(
                svc, _KILL_RESTORE_DEFAULTS.get(svc, 1)
            )
            results.append(k8s.scale(svc, restore))
    return {"restored": results}


def _status_kill_service() -> dict[str, Any]:
    killed: list[str] = []
    for svc in _killable_services():
        if not k8s.deployment_exists(svc):
            continue
        replicas = k8s.current_replicas(svc)
        if replicas == 0:
            killed.append(svc)
    return {
        "state": "armed" if killed else "clear",
        "observed": {"killed": killed, "killable": _killable_services()},
    }


def _inject_pod_restart_gateway(_params: dict[str, Any] | None) -> dict[str, Any]:
    return k8s.delete_random_pod("app.kubernetes.io/name=api-gateway")


def _clear_pod_restart_gateway() -> dict[str, Any]:
    # Transient: nothing to revert. Kubernetes recreates the pod from
    # the deployment template; the chaos action is the deletion itself.
    return {"transient": True}


def _status_pod_restart_gateway() -> dict[str, Any]:
    return {"state": "clear", "observed": {"note": "transient action; no persistent state"}}


def _inject_scale_zero(deployment: str) -> dict[str, Any]:
    return k8s.scale(deployment, 0)


def _clear_scale_zero(deployment: str, restore_to: int = 1) -> dict[str, Any]:
    if not k8s.deployment_exists(deployment):
        return {"restored": False, "reason": f"deployment {deployment} not found"}
    return k8s.scale(deployment, restore_to)


def _status_scale_zero(deployment: str) -> dict[str, Any]:
    return _status_scale_to_zero(deployment)


def _inject_postgres_outage(_params: dict[str, Any] | None) -> dict[str, Any]:
    return _inject_scale_zero("postgres")


def _clear_postgres_outage() -> dict[str, Any]:
    return _clear_scale_zero("postgres")


def _status_postgres_outage() -> dict[str, Any]:
    return _status_scale_zero("postgres")


def _inject_redis_outage(_params: dict[str, Any] | None) -> dict[str, Any]:
    return _inject_scale_zero("redis")


def _clear_redis_outage() -> dict[str, Any]:
    return _clear_scale_zero("redis")


def _status_redis_outage() -> dict[str, Any]:
    return _status_scale_zero("redis")


def _inject_kafka_outage(_params: dict[str, Any] | None) -> dict[str, Any]:
    return _inject_scale_zero("kafka")


def _clear_kafka_outage() -> dict[str, Any]:
    return _clear_scale_zero("kafka")


def _status_kafka_outage() -> dict[str, Any]:
    return _status_scale_zero("kafka")


# ---------------------------------------------------------------------------
# Orchestrator shims. The payment-meltdown scenario is implemented as a
# long-running background thread (see orchestrators.MeltdownRunner) so we
# expose it to the catalog through three small wrappers that match the
# regular Scenario shape. The runner is a module-level singleton, so
# these shims are stateless and re-entrant.
#
# The dispatcher writes the operator name into params[ACTOR_PARAM_KEY]
# before calling inject(); we pop it here so the runner can attribute
# per-phase audit events to the user who clicked Inject (not just to
# the synthetic "ops-dashboard" fallback that other auto-emitted
# bookkeeping events use).
# ---------------------------------------------------------------------------


def _inject_payment_meltdown(params: dict[str, Any] | None) -> dict[str, Any]:
    actor = _extract_actor(params)
    return _meltdown_runner.start(params or {}, actor=actor)


def _clear_payment_meltdown() -> dict[str, Any]:
    # The dispatcher emits its own actor-attributed "clear" audit at the
    # HTTP boundary, so the runner-side recovery audit can safely default
    # to "ops-dashboard". Operators wanting full attribution on the
    # cancel path can re-derive it from the dispatcher's audit event,
    # which carries the same scenario id and arrives in the same second.
    return _meltdown_runner.cancel(actor="ops-dashboard")


def _status_payment_meltdown() -> dict[str, Any]:
    return _meltdown_runner.status()


# ---------------------------------------------------------------------------
# Catalog. Every entry has the SAME shape so the dispatcher and the SPA
# can render and execute it uniformly.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Scenario:
    id: str
    name: str
    category: str  # "app", "latency", "tier", "infra"
    narrative: str
    target_service: str
    watch: str
    recovery_hint: str
    severity: str  # "low" | "medium" | "high"
    inject: Callable[[dict[str, Any] | None], dict[str, Any]]
    clear: Callable[[], dict[str, Any]]
    status: Callable[[], dict[str, Any]]
    # Optional parameter descriptor for the SPA form. None when the
    # scenario takes no input.
    param: dict[str, Any] | None = None
    # Mark infra-tier outages so the SPA can force a confirmation modal.
    requires_confirmation: bool = False
    aliases: tuple[str, ...] = field(default_factory=tuple)


CATALOG: tuple[Scenario, ...] = (
    # ---- 0. Story: combined demos ---------------------------------------
    Scenario(
        id="payment-meltdown",
        name="Payment meltdown (db-slow -> postgres-out)",
        category="story",
        narrative=(
            "One-click orchestrator that runs db-slow for ~4 min then "
            "scales postgres to 0 for ~2 min, then auto-recovers. Every "
            "phase emits a chaos audit stitched by a shared story_id so "
            "the whole arc lands in one ITSI Episode. Use for the "
            "RUM -> APM -> Logs -> ITSI / Postgres walkthrough; the "
            "underlying db-slow latency is a real Postgres pg_sleep() so "
            "APM Database Query Performance, pg_stat_statements, and "
            "postgres_exporter all light up. See docs/customer/story-"
            "rum-apm-postgres.md for the click-by-click talk track."
        ),
        target_service="ledger-service + postgres",
        watch=(
            "ACT 1 (db-slow, ~4 min): RUM Sessions persona submit wait; "
            "APM service map ledger-service red & postgres edge slow; "
            "APM Database Query Performance pg_sleep top-N; "
            "ITSI nwpay_l4_postgres active backends. "
            "ACT 2 (postgres-out, ~2 min): RUM rage-click cluster; "
            "APM trace JDBC 'Connection refused'; logs PSQLException; "
            "ITSI nwpay_l4_postgres backends online = 0."
        ),
        recovery_hint=(
            "Auto-recover runs after Act 2 (autorecover=true by "
            "default). Click Clear to abort mid-flight - safe to call "
            "any time; restores DB_LATENCY_MS=0 and postgres replicas=1."
        ),
        severity="high",
        inject=_inject_payment_meltdown,
        clear=_clear_payment_meltdown,
        status=_status_payment_meltdown,
        requires_confirmation=True,
    ),
    # ---- A. App errors ---------------------------------------------------
    Scenario(
        id="bad-deploy-fraud",
        name="Bad deploy: fraud error rate",
        category="app",
        narrative="Bump fraud-detection ERROR_RATE to 20%. Triggers the SWIFT error-rate detector within ~3 min.",
        target_service="fraud-detection-service",
        watch="Detector: [NatWest demo] SWIFT error rate; APM service health.",
        recovery_hint="Click Clear to restore ERROR_RATE=0.02 baseline.",
        severity="medium",
        inject=_inject_bad_deploy_fraud,
        clear=_clear_bad_deploy_fraud,
        status=_status_bad_deploy_fraud,
    ),
    Scenario(
        id="swift-counterparty-flap",
        name="SWIFT counterparty flap",
        category="app",
        narrative="External SWIFT counterparty starts rejecting payments. ERROR_RATE jumps to 30% on swift-network.",
        target_service="swift-network",
        watch="Detector: SWIFT error rate; error-rate-by-country chart.",
        recovery_hint="Clear restores ERROR_RATE=0.05.",
        severity="medium",
        inject=_inject_swift_counterparty_flap,
        clear=_clear_swift_counterparty_flap,
        status=_status_swift_counterparty_flap,
    ),
    Scenario(
        id="swift-scheme-outage",
        name="SWIFT scheme outage (fraud check)",
        category="app",
        narrative="Multiply SWIFT errors out of fraud-detection by 5x. Tail of cross-border declines, others stay clean.",
        target_service="fraud-detection-service",
        watch="Decline rate by scheme; APM error-rate breakdown for SWIFT.",
        recovery_hint="Clear restores SCHEME_ERROR_MULTIPLIERS=SWIFT:3,CHAPS:2.",
        severity="medium",
        inject=_inject_swift_scheme_outage,
        clear=_clear_swift_scheme_outage,
        status=_status_swift_scheme_outage,
    ),
    Scenario(
        id="settlement-producer-off",
        name="Settlement producer offline",
        category="app",
        narrative="Disable Kafka producer on payment-initiation. Settlement consumer stops seeing messages.",
        target_service="payment-initiation-service",
        watch="Kafka lag; settlement-service trace volume drops; async edge missing on APM service map.",
        recovery_hint="Clear re-enables KAFKA_PRODUCER_ENABLED.",
        severity="medium",
        inject=_inject_settlement_producer_off,
        clear=_clear_settlement_producer_off,
        status=_status_settlement_producer_off,
    ),
    Scenario(
        id="sanctions-cache-disabled",
        name="Sanctions cache disabled",
        category="app",
        narrative="Force every sanctions/AML lookup to miss the Redis cache. P95 latency grows on the payment chain.",
        target_service="sanctions-aml-service",
        watch="Sanctions cache miss-rate detector; AlwaysOn flamegraph for the new sanctions hot path.",
        recovery_hint="Clear re-enables CACHE_ENABLED.",
        severity="medium",
        inject=_inject_sanctions_cache_disabled,
        clear=_clear_sanctions_cache_disabled,
        status=_status_sanctions_cache_disabled,
    ),
    # ---- B. Latency ------------------------------------------------------
    Scenario(
        id="db-slow",
        name="Ledger DB slow",
        category="latency",
        narrative=(
            "Inject 200 ms latency into every ledger-service Postgres query. "
            "The latency is a REAL Postgres pg_sleep() issued inside the "
            "@Transactional method, so it shows up as a slow JDBC span in "
            "APM, a top-N entry in pg_stat_statements (APM Database Query "
            "Performance + ITSI nwpay_l4_postgres), and as held connection "
            "time on postgres_exporter. ACT 1 of the payment-meltdown story; "
            "follow with postgres-outage for the full RUM-to-DB walkthrough."
        ),
        target_service="ledger-service",
        watch=(
            "RUM Sessions / replay: persona submit-button wait. "
            "APM service map: ledger-service red, postgres edge slow. "
            "APM Database Query Performance: SELECT pg_sleep top-N. "
            "ITSI nwpay_l4_postgres: active backends, cache hit ratio. "
            "Detector: payment-initiation p99 latency SLO."
        ),
        recovery_hint="Clear restores DB_LATENCY_MS=0.",
        severity="medium",
        inject=_inject_db_slow,
        clear=_clear_db_slow,
        status=_status_db_slow,
    ),
    Scenario(
        id="fraud-cpu-regression",
        name="Fraud CPU regression",
        category="latency",
        narrative="Swap the linear feature extractor for the O(N^2) one. Same outputs, 30x more CPU.",
        target_service="fraud-detection-service",
        watch="AlwaysOn Profiling diff: _extract_features_pairwise tower; fraud p99 climbs.",
        recovery_hint="Clear restores CPU_REGRESSION_ENABLED=false.",
        severity="medium",
        inject=_inject_fraud_cpu_regression,
        clear=_clear_fraud_cpu_regression,
        status=_status_fraud_cpu_regression,
    ),
    Scenario(
        id="tail-latency-storm",
        name="Tail-latency storm",
        category="latency",
        narrative="10% of payment-validation calls grow a 1.5-4.5 s tail. Wrecks p99 without breaking p50.",
        target_service="payment-validation-service",
        watch="APM p99 trend; trace search for spans > 1 s.",
        recovery_hint="Clear restores TAIL_LATENCY_RATE=0.",
        severity="medium",
        inject=_inject_tail_latency_storm,
        clear=_clear_tail_latency_storm,
        status=_status_tail_latency_storm,
    ),
    Scenario(
        id="latency-creep",
        name="Payment-status latency creep",
        category="latency",
        narrative="Push LATENCY_MS_MEAN to 200 on payment-status-service. Slow GET /status everywhere in the SPA.",
        target_service="payment-status-service",
        watch="RUM custom-event duration for status calls; APM service health.",
        recovery_hint="Clear restores LATENCY_MS_MEAN=10.",
        severity="low",
        inject=_inject_latency_creep,
        clear=_clear_latency_creep,
        status=_status_latency_creep,
    ),
    Scenario(
        id="gateway-timeout-squeeze",
        name="Gateway timeout squeeze",
        category="latency",
        narrative="Drop api-gateway downstream timeout to 0.5 s. Anything tail-latent now times out at the gateway.",
        target_service="api-gateway",
        watch="HTTP 504 / 5xx rate at the gateway; trace error count.",
        recovery_hint="Clear restores DOWNSTREAM_TIMEOUT_S=12.0.",
        severity="high",
        inject=_inject_gateway_timeout_squeeze,
        clear=_clear_gateway_timeout_squeeze,
        status=_status_gateway_timeout_squeeze,
    ),
    Scenario(
        id="madrid-network-degradation",
        name="Madrid network degradation",
        category="latency",
        narrative="Bump Madrid RTT to ~2 s on the traffic generator. p95 by customer.location lights up Madrid only - other cities stay flat.",
        target_service="traffic-generator",
        watch="APM / RUM p95 by customer.location; ITSI 'Payments by location' KPI.",
        recovery_hint="Clear restores LOCATION_LATENCY_PROFILES='' (baseline 450 +/- 120 ms).",
        severity="medium",
        inject=_inject_madrid_degradation,
        clear=_clear_madrid_degradation,
        status=_status_madrid_degradation,
    ),
    Scenario(
        id="traffic-steady-state",
        name="Traffic steady state (lower RPS)",
        category="latency",
        narrative=(
            "Drop the traffic-generator to 12 RPS with no time-of-day schedule "
            "so the payment chain can drain gunicorn queues after a chaos arc. "
            "Use before a demo walk-through when the APM service map is still red."
        ),
        target_service="traffic-generator",
        watch="APM service-map health rings; api-gateway payment-initiation read timeouts in logs.",
        recovery_hint="Clear restores RPS=25 and the weekday RPS_SCHEDULE curve.",
        severity="low",
        inject=_inject_traffic_steady_state,
        clear=_clear_traffic_steady_state,
        status=_status_traffic_steady_state,
    ),
    # ---- C. Customer tier -----------------------------------------------
    Scenario(
        id="tier-throttle",
        name="Tier throttle",
        category="tier",
        narrative="Throttle a single customer tier at api-gateway. Other tiers stay clean - that's the story.",
        target_service="api-gateway",
        watch="Decline+throttle rate by tier; RUM page-error count for the matching persona.",
        recovery_hint="Clear restores TIER_THROTTLE_PROB to baseline.",
        severity="medium",
        inject=_inject_tier_throttle,
        clear=_clear_tier_throttle,
        status=_status_tier_throttle,
        param={
            "name": "tier",
            "label": "Customer tier to throttle",
            "type": "select",
            "options": list(KNOWN_TIERS),
            "default": "bronze",
        },
    ),
    Scenario(
        id="cache-cold",
        name="Cache cold (sanctions)",
        category="tier",
        narrative="Drop sanctions-aml-service CACHE_HIT_RATE to 0.40 - cache warm-up incident.",
        target_service="sanctions-aml-service",
        watch="Sanctions cache miss-rate detector; cache-hit-ratio chart.",
        recovery_hint="Clear restores CACHE_HIT_RATE=0.97.",
        severity="medium",
        inject=_inject_cache_cold,
        clear=_clear_cache_cold,
        status=_status_cache_cold,
    ),
    Scenario(
        id="gold-fast-path-off",
        name="Gold fast-path disabled",
        category="tier",
        narrative=(
            "Remove the fraud fast-path bias for Gold tier only "
            "(bronze:0.0, silver:0.2, gold:0.0). Bronze and Silver keep their "
            "baseline behaviour - only Gold customers now follow the slow "
            "code path and feel the latency hit."
        ),
        target_service="fraud-detection-service",
        watch=(
            "ITSI 'Customer Tier Experience' service - only the Gold p95 "
            "latency KPI should paint red; Silver and Bronze stay normal."
        ),
        recovery_hint="Clear restores TIER_FRAUD_FAST_PATH_PROB to baseline (silver:0.2, gold:0.6).",
        severity="medium",
        inject=_inject_gold_fast_path_off,
        clear=_clear_gold_fast_path_off,
        status=_status_gold_fast_path_off,
    ),
    # ---- D. Infrastructure outages --------------------------------------
    Scenario(
        id="apm-topology-repair",
        name="APM topology repair (steady state)",
        category="infra",
        narrative=(
            "Re-apply the steady-state env vars and replica counts that keep "
            "the Splunk APM service map fully connected: traffic-generator "
            "-> api-gateway, payment-initiation -> kafka -> settlement, "
            "ledger -> postgres, api-gateway at 2 replicas, routing at 2. "
            "Run after chaos demos or whenever nodes look like floating islands."
        ),
        target_service="multi",
        watch="APM service map edges; traffic-generator and settlement-service connectivity.",
        recovery_hint="Idempotent - safe to click Inject or Clear any time.",
        severity="low",
        inject=_inject_apm_topology_repair,
        clear=_clear_apm_topology_repair,
        status=_status_apm_topology_repair,
    ),
    Scenario(
        id="kill-service",
        name="Kill service (scale to 0)",
        category="infra",
        narrative="Scale an allow-listed deployment to 0 replicas. Triggers downstream 5xx cascade.",
        target_service="(parameterised)",
        watch="Pod ready count; APM service map; gateway error-rate detector.",
        recovery_hint="Clear restores killable services back to 1 replica.",
        severity="high",
        inject=_inject_kill_service,
        clear=_clear_kill_service,
        status=_status_kill_service,
        param={
            "name": "service",
            "label": "Service to kill",
            "type": "select",
            "options": _killable_services(),
            "default": _killable_services()[0] if _killable_services() else "",
        },
        requires_confirmation=True,
    ),
    Scenario(
        id="pod-restart-gateway",
        name="Pod restart (api-gateway)",
        category="infra",
        narrative="Delete a random api-gateway pod. K8s recreates it; brief blip on RUM page-error.",
        target_service="api-gateway",
        watch="Pod count; HTTP 5xx blip on api-gateway; restart count.",
        recovery_hint="Transient - no action needed. The pod is recreated automatically.",
        severity="medium",
        inject=_inject_pod_restart_gateway,
        clear=_clear_pod_restart_gateway,
        status=_status_pod_restart_gateway,
        requires_confirmation=True,
    ),
    Scenario(
        id="pod-restart-service",
        name="Pod restart (parameterised)",
        category="infra",
        narrative=(
            "Delete one pod from a restartable deployment so Kubernetes "
            "recreates it. Use to clear gunicorn queue saturation on "
            "payment-initiation-service or routing-service after chaos."
        ),
        target_service="(parameterised)",
        watch="Pod ready count; brief error/latency blip on the target service.",
        recovery_hint="Transient - no action needed.",
        severity="medium",
        inject=_inject_pod_restart_service,
        clear=_clear_pod_restart_service,
        status=_status_pod_restart_service,
        param={
            "name": "service",
            "label": "Deployment to restart",
            "type": "select",
            "options": _restartable_services(),
            "default": "payment-initiation-service",
        },
        requires_confirmation=True,
    ),
    Scenario(
        id="postgres-outage",
        name="Postgres outage",
        category="infra",
        narrative=(
            "Scale postgres to 0. ledger-service starts failing JDBC calls "
            "with PSQLException. ACT 2 of the payment-meltdown story: pair "
            "with db-slow first to walk RUM session replay -> APM service "
            "map -> APM trace 'Logs for this trace' -> ITSI nwpay_l4_postgres "
            "KPIs in red, all linked by a single story_id."
        ),
        target_service="postgres",
        watch=(
            "RUM Sessions: rage-click cluster on the latest persona submit. "
            "APM service map: ledger-service error rate, postgres edge red/missing. "
            "APM trace: JDBC span carries 'Connection refused'. "
            "Logs: PSQLException in index=main sourcetype=kube:container:service. "
            "ITSI nwpay_l4_postgres: backends online = 0."
        ),
        recovery_hint="Clear scales postgres back to 1.",
        severity="high",
        inject=_inject_postgres_outage,
        clear=_clear_postgres_outage,
        status=_status_postgres_outage,
        requires_confirmation=True,
    ),
    Scenario(
        id="redis-outage",
        name="Redis outage",
        category="infra",
        narrative="Scale redis to 0. Sanctions/Fraud cache lookups fail; SPA recent-payments view stops updating.",
        target_service="redis",
        watch="Redis client error rate; cache miss-rate; SPA /recent staleness.",
        recovery_hint="Clear scales redis back to 1.",
        severity="high",
        inject=_inject_redis_outage,
        clear=_clear_redis_outage,
        status=_status_redis_outage,
        requires_confirmation=True,
    ),
    Scenario(
        id="kafka-outage",
        name="Kafka outage",
        category="infra",
        narrative="Scale kafka broker to 0. payment-initiation producer fails; settlement-service consumer stalls.",
        target_service="kafka",
        watch="Kafka producer error rate; consumer lag; APM async edge breaks.",
        recovery_hint="Clear scales kafka back to 1.",
        severity="high",
        inject=_inject_kafka_outage,
        clear=_clear_kafka_outage,
        status=_status_kafka_outage,
        requires_confirmation=True,
    ),
)


_INDEX: dict[str, Scenario] = {s.id: s for s in CATALOG}


def get(scenario_id: str) -> Scenario | None:
    """Look up a scenario by allow-listed id. Returns None on unknown id."""
    if not isinstance(scenario_id, str):
        return None
    return _INDEX.get(scenario_id.strip())


def all_scenarios() -> tuple[Scenario, ...]:
    return CATALOG


def scenario_meta(scn: Scenario, include_status: bool = True) -> dict[str, Any]:
    """Serialise a Scenario for the SPA / catalog endpoint.

    Status is computed lazily so the catalog GET only does the API
    round-trip when the caller asks for it (the SPA always does).
    """
    out: dict[str, Any] = {
        "id": scn.id,
        "name": scn.name,
        "category": scn.category,
        "narrative": scn.narrative,
        "target_service": scn.target_service,
        "watch": scn.watch,
        "recovery_hint": scn.recovery_hint,
        "severity": scn.severity,
        "param": scn.param,
        "requires_confirmation": scn.requires_confirmation,
    }
    if include_status:
        try:
            out["status"] = scn.status()
        except Exception as exc:  # noqa: BLE001 - status must never crash the catalog
            LOG.warning("status_failed scenario=%s err=%s", scn.id, exc)
            out["status"] = {"state": "unknown", "observed": {"error": str(exc)[:200]}}
    return out
