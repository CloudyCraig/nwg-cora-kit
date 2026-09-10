"""chaos-controller HTTP API.

Endpoints (all under ``/chaos/api/`` so the same-origin nginx reverse
proxy keeps the RUM trust list small):

  * ``GET  /chaos/api/scenarios``      - allow-listed catalog + live status.
  * ``GET  /chaos/api/health``         - readiness probe.
  * ``POST /chaos/api/<id>/inject``    - apply a scenario (optional JSON body).
  * ``POST /chaos/api/<id>/clear``     - revert a scenario.
  * ``POST /chaos/api/recover``        - revert every scenario in catalog order.

All POSTs require the ``X-Chaos-Token`` header (see auth.py) and are
rate-limited to one action per scenario every 2 seconds to prevent
fat-finger double-fires from clobbering the cluster.

Every mutating call emits one ``nwpay:chaos`` HEC event via audit.py
in the same shape ``scripts/incident.sh`` produces, so the existing
SIEM correlation searches keep working without change.
"""

from __future__ import annotations

import logging
import os
import threading
import time
from typing import Any

from flask import Flask, jsonify, request
from werkzeug.exceptions import HTTPException

from .audit import emit_chaos_audit
from .auth import auth_configured, require_presenter_token
from .scenarios import (
    ACTOR_PARAM_KEY,
    all_scenarios,
    get as get_scenario,
    scenario_meta,
)

LOG = logging.getLogger("chaos-controller")
logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)


def create_app() -> Flask:
    app = Flask(__name__)
    app.url_map.strict_slashes = False

    # ---------------------------------------------------------------
    # Rate limiter. Per-scenario in-process token bucket. The chaos
    # controller is a single deployment with one replica, so
    # in-process state is sufficient for a 1-action-per-2-seconds
    # guard. If we ever scale > 1 replica, this becomes per-pod best-
    # effort - that's acceptable for a demo control plane.
    # ---------------------------------------------------------------
    rate_lock = threading.Lock()
    last_action_ts: dict[str, float] = {}
    min_gap_s = float(os.environ.get("CHAOS_MIN_GAP_S", "2.0"))

    def rate_allowed(scenario_id: str) -> bool:
        with rate_lock:
            now = time.monotonic()
            last = last_action_ts.get(scenario_id, 0.0)
            if now - last < min_gap_s:
                return False
            last_action_ts[scenario_id] = now
            return True

    # ---------------------------------------------------------------
    # JSON error responses. Werkzeug's default HTML pages would
    # confuse the SPA fetch client; we return application/json with
    # a stable shape regardless of the HTTPException raised.
    # ---------------------------------------------------------------
    @app.errorhandler(HTTPException)
    def handle_http_error(exc: HTTPException) -> Any:
        body = {"error": exc.name, "status": exc.code, "message": exc.description}
        return jsonify(body), exc.code or 500

    @app.errorhandler(Exception)
    def handle_unexpected(exc: Exception) -> Any:  # noqa: BLE001
        LOG.exception("unhandled_error err=%s", exc)
        return (
            jsonify(
                {
                    "error": "InternalServerError",
                    "status": 500,
                    "message": str(exc)[:300],
                }
            ),
            500,
        )

    # ---------------------------------------------------------------
    # Endpoints.
    # ---------------------------------------------------------------

    @app.get("/chaos/api/health")
    def health() -> Any:
        return jsonify(
            {
                "status": "ok",
                "auth_configured": auth_configured(),
                "namespace": os.environ.get("NAMESPACE", "natwest"),
                "scenarios": len(all_scenarios()),
            }
        )

    @app.get("/chaos/api/scenarios")
    @require_presenter_token
    def scenarios() -> Any:
        items = [scenario_meta(scn, include_status=True) for scn in all_scenarios()]
        armed = sum(1 for it in items if it.get("status", {}).get("state") == "armed")
        return jsonify(
            {
                "scenarios": items,
                "armed_count": armed,
                "total": len(items),
            }
        )

    def _actor() -> str:
        # Best-effort attribution. The SPA can attach an X-Operator
        # header (the logged-in username) for the audit trail; we fall
        # back to "ops-dashboard" when missing. Never crash on weird
        # header values.
        raw = request.headers.get("X-Operator", "").strip()
        return raw[:64] if raw else "ops-dashboard"

    def _body_params() -> dict[str, Any]:
        if not request.data:
            return {}
        try:
            body = request.get_json(silent=True) or {}
        except Exception:  # noqa: BLE001
            return {}
        return body if isinstance(body, dict) else {}

    @app.post("/chaos/api/<scenario_id>/inject")
    @require_presenter_token
    def inject(scenario_id: str) -> Any:
        scn = get_scenario(scenario_id)
        if scn is None:
            return jsonify({"error": "unknown scenario", "scenario_id": scenario_id}), 404
        if not rate_allowed(scn.id):
            return (
                jsonify(
                    {
                        "error": "rate limited",
                        "scenario_id": scn.id,
                        "min_gap_s": min_gap_s,
                    }
                ),
                429,
            )
        params = _body_params()
        actor = _actor()
        # Plumb the operator through to orchestrator scenarios that need
        # per-phase audit attribution (currently just payment-meltdown).
        # Regular scenarios ignore the key. Pop happens inside the
        # scenario shim so it never leaks into the audit "params" echo.
        inject_params = dict(params)
        inject_params[ACTOR_PARAM_KEY] = actor
        try:
            result = scn.inject(inject_params)
        except ValueError as exc:
            return jsonify({"error": str(exc), "scenario_id": scn.id}), 400
        except RuntimeError as exc:
            # Long-running orchestrators raise RuntimeError("...already
            # running...") when start() is called twice. Surface that as
            # a 409 Conflict so the SPA can distinguish "you double-
            # clicked" from "k8s API is broken". Other RuntimeErrors map
            # to 502 like before.
            LOG.warning("inject_runtime_error scenario=%s err=%s", scn.id, exc)
            status_code = 409 if "already running" in str(exc) else 502
            return jsonify({"error": str(exc), "scenario_id": scn.id}), status_code
        emit_chaos_audit(
            action="inject",
            scenario=scn.id,
            target_service=scn.target_service,
            actor=actor,
            details={"params": params, "result": result},
        )
        return jsonify(
            {
                "scenario_id": scn.id,
                "action": "inject",
                "result": result,
                "params": params,
            }
        )

    @app.post("/chaos/api/<scenario_id>/clear")
    @require_presenter_token
    def clear(scenario_id: str) -> Any:
        scn = get_scenario(scenario_id)
        if scn is None:
            return jsonify({"error": "unknown scenario", "scenario_id": scenario_id}), 404
        if not rate_allowed(scn.id):
            return (
                jsonify(
                    {
                        "error": "rate limited",
                        "scenario_id": scn.id,
                        "min_gap_s": min_gap_s,
                    }
                ),
                429,
            )
        try:
            result = scn.clear()
        except RuntimeError as exc:
            LOG.warning("clear_runtime_error scenario=%s err=%s", scn.id, exc)
            return jsonify({"error": str(exc), "scenario_id": scn.id}), 502
        emit_chaos_audit(
            action="clear",
            scenario=scn.id,
            target_service=scn.target_service,
            actor=_actor(),
            details={"result": result},
        )
        return jsonify(
            {"scenario_id": scn.id, "action": "clear", "result": result}
        )

    @app.post("/chaos/api/recover")
    @require_presenter_token
    def recover() -> Any:
        results: dict[str, Any] = {}
        actor = _actor()
        for scn in all_scenarios():
            if scn.id == "apm-topology-repair":
                # Run topology repair once, after every other scenario clear.
                continue
            try:
                results[scn.id] = scn.clear()
            except RuntimeError as exc:
                LOG.warning("recover_runtime_error scenario=%s err=%s", scn.id, exc)
                results[scn.id] = {"error": str(exc)}
        repair = get_scenario("apm-topology-repair")
        if repair is not None:
            try:
                results[repair.id] = repair.clear()
            except RuntimeError as exc:
                LOG.warning("recover_topology_repair_error err=%s", exc)
                results[repair.id] = {"error": str(exc)}
        emit_chaos_audit(
            action="clear",
            scenario="recover-all",
            target_service="multi",
            actor=actor,
            details={"results": results},
        )
        return jsonify({"action": "recover", "results": results})

    return app


app = create_app()
