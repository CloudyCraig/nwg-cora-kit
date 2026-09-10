"""HEC audit emitter for the chaos-controller.

Posts one ``nwpay:chaos`` event to Splunk Enterprise per inject/clear,
in the exact same shape that ``scripts/incident.sh::emit_chaos_audit``
produces, so the existing ITSI / SIEM correlation searches
(``chaos_off_change_window``, ``payments_excessive_declines_by_tier``)
keep working without modification.

The HEC token + endpoint are mounted from the same secret the
incident.sh script reads via Terraform output. If either is missing the
emitter logs a single warning at startup and silently drops events
thereafter - chaos must never depend on the audit pipeline being up.
"""

from __future__ import annotations

import json
import logging
import os
import time
import uuid
from typing import Any

import requests

LOG = logging.getLogger("chaos-controller.audit")

_HEC_ENDPOINT_ENV = "SPLUNK_HEC_ENDPOINT"
_HEC_TOKEN_ENV = "SPLUNK_HEC_TOKEN"
_HEC_INDEX_ENV = "SPLUNK_HEC_INDEX"
_HEC_INSECURE_ENV = "SPLUNK_HEC_INSECURE"
_HEC_SOURCETYPE = "nwpay:chaos"
_HEC_DEFAULT_INDEX = "nwpay_audit"
_HEC_TIMEOUT_S = 5


def _bool_env(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _endpoint() -> str:
    return os.environ.get(_HEC_ENDPOINT_ENV, "").strip()


def _token() -> str:
    return os.environ.get(_HEC_TOKEN_ENV, "").strip()


def _index() -> str:
    return os.environ.get(_HEC_INDEX_ENV, _HEC_DEFAULT_INDEX).strip() or _HEC_DEFAULT_INDEX


def _verify_tls() -> bool:
    # Default to verify=False because the demo Splunk Enterprise uses a
    # self-signed cert. Operators with a trusted CA can flip
    # ``SPLUNK_HEC_INSECURE=0`` to enforce verification.
    return not _bool_env(_HEC_INSECURE_ENV, True)


def _now_iso() -> str:
    return time.strftime(
        "%Y-%m-%dT%H:%M:%S." + f"{int((time.time() % 1) * 1000):03d}Z",
        time.gmtime(),
    )


def emit_chaos_audit(
    action: str,
    scenario: str,
    target_service: str | None,
    actor: str | None,
    details: dict[str, Any] | None = None,
) -> None:
    """Send one chaos audit event to Splunk Enterprise via HEC.

    Best-effort: any network/HTTP failure is logged at WARNING and
    swallowed so a flaky HEC never blocks a chaos action.

    Parameters
    ----------
    action: "inject" or "clear" (anything else is coerced to "inject").
    scenario: canonical id from the catalog (e.g. "bad-deploy-fraud").
    target_service: deployment touched, or "multi" for recover().
    actor: presenter user name; "ops-dashboard" when unattributed.
    details: scenario-specific extras (error_rate, replicas, tier, ...).
    """
    endpoint = _endpoint()
    token = _token()
    if not endpoint or not token:
        LOG.debug("chaos_audit_skipped reason=hec_not_configured scenario=%s", scenario)
        return

    safe_action = "clear" if str(action).strip().lower() == "clear" else "inject"
    event_body: dict[str, Any] = {
        "@timestamp": _now_iso(),
        "event_type": "chaos",
        "scenario": str(scenario)[:64],
        "target_service": str(target_service)[:64] if target_service else None,
        "actor": str(actor)[:64] if actor else "ops-dashboard",
        "action": safe_action,
        "event_id": f"chaos-{int(time.time())}-{uuid.uuid4().hex[:8]}",
        "details": details if isinstance(details, dict) else None,
    }
    event_body = {k: v for k, v in event_body.items() if v is not None}

    payload = {
        "event": event_body,
        "sourcetype": _HEC_SOURCETYPE,
        "index": _index(),
        "time": int(time.time()),
    }

    try:
        resp = requests.post(
            endpoint,
            data=json.dumps(payload),
            headers={
                "Authorization": f"Splunk {token}",
                "Content-Type": "application/json",
            },
            timeout=_HEC_TIMEOUT_S,
            verify=_verify_tls(),
        )
        if not resp.ok:
            LOG.warning(
                "chaos_audit_http_error status=%s scenario=%s body=%s",
                resp.status_code,
                scenario,
                resp.text[:200],
            )
    except requests.RequestException as exc:  # noqa: BLE001
        LOG.warning("chaos_audit_network_error scenario=%s err=%s", scenario, exc)
