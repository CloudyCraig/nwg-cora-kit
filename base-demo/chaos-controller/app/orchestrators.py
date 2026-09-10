"""Long-running chaos orchestrators.

A normal Scenario in :mod:`chaos-controller.app.scenarios` is a
synchronous inject -> clear pair: the operator clicks Inject, the
dispatcher calls ``scenario.inject(params)``, the cluster mutates,
and a single audit event is emitted. That model breaks for the
``payment-meltdown`` story because the value is in the *sequence*:

    Act 1 (~4 min): db-slow      -> walk RUM, APM, DB Query Perf, logs
    Act 2 (~2 min): postgres-out -> walk RUM rage, APM 5xx, JDBC logs
    Recover       : restore both -> single ITSI Episode closes

We want one button on the SPA that drives both acts with operator-
tunable pacing, emits per-phase HEC audits stitched by a shared
``story_id``, and stays cancellable mid-flight (operator clicks Clear,
the cluster recovers immediately and the run ends).

This module hosts the singleton :class:`MeltdownRunner` that backs
those semantics. The scenario in ``scenarios.py`` is just three small
shims around ``runner.start()`` / ``runner.cancel()`` / ``runner.status()``.

Design notes
------------
* Threading, not asyncio: Flask 3.x dev server and gunicorn workers
  are sync. A background ``threading.Thread`` survives the request
  lifetime, can be polled cheaply from ``status()``, and matches the
  controller's existing rate-limiter (also threading-based).
* In-process singleton: the controller runs as a single replica
  (chart pins ``replicas: 1``), so a module-level instance is safe.
  If we ever scale > 1 a future operator should move the runner to a
  Kubernetes Lease / Redis key. The status() shape is stable enough
  that the migration is a swap of the storage backend.
* Direct k8s.* calls: the runner reaches into :mod:`k8s` rather than
  recursing through the HTTP layer. That avoids re-checking auth on
  internally-issued mutations and means a long-running story keeps
  going even if the dispatcher's token rotates mid-run.
* Audit emission per phase: the runner emits ``inject`` events when
  each act starts and a ``clear`` event when the story ends (success,
  cancel, or error). Every event carries the shared ``story_id`` in
  ``details`` so the SIEM correlation searches stitch the run into
  one ITSI Episode. The dispatcher's own ``inject``/``clear`` audits
  (one per HTTP call) form the bookends.
* Safe defaults clamp: act durations cap at 30 minutes each to make
  a typo via params (e.g. ``act1_s=999999``) impossible to wedge the
  cluster overnight.
"""

from __future__ import annotations

import logging
import os
import threading
import time
import uuid
from dataclasses import dataclass
from typing import Any

from . import k8s
from .audit import emit_chaos_audit
from .o11y_events import emit_o11y_event

LOG = logging.getLogger("chaos-controller.orchestrators")

# ---------------------------------------------------------------------------
# Defaults. Match scripts/incident.sh::cmd_payment_meltdown so the two paths
# (CLI / SPA) produce the same demo cadence. Operator can override per-run
# via the SPA inject params or env-var defaults (env wins over hard-coded
# fallback, params win over both).
# ---------------------------------------------------------------------------

_DEFAULT_DB_LATENCY_MS = int(os.environ.get("MELTDOWN_DB_LATENCY_MS", "400"))
_DEFAULT_ACT1_S = int(os.environ.get("MELTDOWN_ACT1_S", "240"))
_DEFAULT_ACT2_S = int(os.environ.get("MELTDOWN_ACT2_S", "120"))
_DEFAULT_AUTORECOVER = os.environ.get("MELTDOWN_AUTORECOVER", "1").strip().lower() in {
    "1",
    "true",
    "yes",
    "on",
}
_DEFAULT_POSTGRES_DEPLOY = os.environ.get("MELTDOWN_POSTGRES_DEPLOY", "postgres").strip() or "postgres"

# Defence-in-depth caps. If a typo or malicious caller asks for a 99-hour
# act, we silently clamp at 30 minutes. Same shape as the LedgerController
# 30 s pg_sleep clamp.
_MAX_ACT_S = 30 * 60
_MIN_ACT_S = 1


# Phases used by status() so the SPA can render a progress label.
_PHASE_IDLE = "idle"
_PHASE_ACT1 = "act1-db-slow"
_PHASE_ACT2 = "act2-postgres-outage"
_PHASE_RECOVER = "recovering"
_PHASE_COMPLETE = "complete"

# Scenario id used in audit emissions. Must match the catalog entry id
# in scenarios.py so the SIEM correlation searches see one consistent
# scenario name across all the per-phase audit events.
_AUDIT_SCENARIO = "payment-meltdown"

# Canonical SPA persona + payment context for the meltdown story. Keep in
# sync with frontend/src/storyDemo.ts and scripts/incident.sh STORY_* vars.
_STORY_AUDIT_CONTEXT: dict[str, Any] = {
    "customer_id": os.environ.get("STORY_MELTDOWN_CUSTOMER_ID", "cust-uk-003"),
    "customer_name": os.environ.get("STORY_MELTDOWN_CUSTOMER_NAME", "Margaret"),
    "customer_tier": os.environ.get("STORY_MELTDOWN_CUSTOMER_TIER", "gold"),
    "payment_scheme": os.environ.get("STORY_MELTDOWN_PAYMENT_SCHEME", "FPS"),
    "payee_name": os.environ.get("STORY_MELTDOWN_PAYEE_NAME", "Henry (grandson)"),
    "payment_reference": os.environ.get(
        "STORY_MELTDOWN_PAYMENT_REFERENCE", "Pocket money"
    ),
    "amount_minor_units": int(os.environ.get("STORY_MELTDOWN_AMOUNT_MINOR", "2500")),
}


def _clamp_act_seconds(name: str, raw: Any, default_s: int) -> int:
    """Return a sanitised duration, clamped to [_MIN_ACT_S, _MAX_ACT_S].

    Raises ValueError on non-numeric input so the dispatcher returns a
    400 to the SPA rather than a silent fallback. We *do* silently
    clamp out-of-range numerics because the goal is a safe demo, not
    parameter pedantry.
    """
    if raw is None or raw == "":
        return default_s
    try:
        value = int(float(raw))
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} must be numeric, got {raw!r}") from exc
    if value < _MIN_ACT_S:
        return _MIN_ACT_S
    if value > _MAX_ACT_S:
        return _MAX_ACT_S
    return value


def _clamp_db_latency_ms(raw: Any, default_ms: int) -> int:
    """Same shape as _clamp_act_seconds for DB_LATENCY_MS overrides.

    Hard upper bound is 30_000 ms to match the LedgerController's
    Java-side pg_sleep clamp. Going beyond would just be silently
    re-capped inside the service - clamp here so the audit reflects
    the value actually used.
    """
    if raw is None or raw == "":
        return default_ms
    try:
        value = int(float(raw))
    except (TypeError, ValueError) as exc:
        raise ValueError(f"db_latency_ms must be numeric, got {raw!r}") from exc
    if value < 0:
        return 0
    if value > 30_000:
        return 30_000
    return value


@dataclass
class MeltdownState:
    """Snapshot of the runner's internal state. Read-only outside the runner."""

    phase: str = _PHASE_IDLE
    story_id: str | None = None
    started_at: float | None = None
    phase_started_at: float | None = None
    db_latency_ms: int = 0
    act1_s: int = 0
    act2_s: int = 0
    autorecover: bool = False
    postgres_deploy: str = _DEFAULT_POSTGRES_DEPLOY
    last_error: str | None = None
    last_actor: str | None = None
    # Set true when cancel() is called. The worker thread checks this
    # on every sleep tick and bails to recovery within at most one
    # tick interval.
    cancel_requested: bool = False


class MeltdownRunner:
    """Singleton orchestrator for the payment-meltdown story."""

    # How often the worker checks the cancel flag while dwelling in
    # an act. Smaller -> snappier cancel response, larger -> fewer
    # context switches. 1s is a fine compromise: cancel always reacts
    # within at most 1s, total wakeups across a 4-min act are bounded.
    _CANCEL_POLL_INTERVAL_S = 1.0

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._state = MeltdownState()
        self._worker: threading.Thread | None = None

    # ----- Public API -----------------------------------------------

    def start(self, params: dict[str, Any] | None, actor: str) -> dict[str, Any]:
        """Kick off a new story. Returns immediately.

        Raises:
            RuntimeError when a story is already in flight (cluster
                only has one Postgres; running two at once is
                nonsense). The dispatcher maps this to HTTP 409.
            ValueError on non-numeric param overrides.
        """
        params = params or {}
        db_latency_ms = _clamp_db_latency_ms(
            params.get("db_latency_ms"), _DEFAULT_DB_LATENCY_MS
        )
        act1_s = _clamp_act_seconds("act1_s", params.get("act1_s"), _DEFAULT_ACT1_S)
        act2_s = _clamp_act_seconds("act2_s", params.get("act2_s"), _DEFAULT_ACT2_S)
        autorecover_raw = params.get("autorecover")
        autorecover = (
            _DEFAULT_AUTORECOVER
            if autorecover_raw is None
            else str(autorecover_raw).strip().lower() in {"1", "true", "yes", "on"}
        )
        postgres_deploy = (
            str(params.get("postgres_deploy", "")).strip() or _DEFAULT_POSTGRES_DEPLOY
        )

        with self._lock:
            if self._state.phase not in (_PHASE_IDLE, _PHASE_COMPLETE):
                raise RuntimeError(
                    f"payment-meltdown already running (phase={self._state.phase}, "
                    f"story_id={self._state.story_id}); click Clear before starting a new story"
                )
            # Verify the postgres deployment exists BEFORE we mutate
            # anything so we can fail fast with a clean error. Catching
            # it here also means the worker thread never has to deal
            # with the missing-deployment case mid-act-2.
            if not k8s.deployment_exists(postgres_deploy):
                raise RuntimeError(
                    f"postgres deployment {postgres_deploy} not found in namespace "
                    f"{k8s.NAMESPACE}; cannot run payment-meltdown"
                )

            story_id = f"meltdown-{int(time.time())}-{uuid.uuid4().hex[:8]}"
            self._state = MeltdownState(
                phase=_PHASE_ACT1,
                story_id=story_id,
                started_at=time.monotonic(),
                phase_started_at=time.monotonic(),
                db_latency_ms=db_latency_ms,
                act1_s=act1_s,
                act2_s=act2_s,
                autorecover=autorecover,
                postgres_deploy=postgres_deploy,
                last_actor=actor,
            )
            self._worker = threading.Thread(
                target=self._run,
                name=f"meltdown-{story_id}",
                daemon=True,
            )
            self._worker.start()

        LOG.info(
            "meltdown.started story_id=%s db_latency_ms=%d act1_s=%d act2_s=%d autorecover=%s actor=%s",
            story_id,
            db_latency_ms,
            act1_s,
            act2_s,
            autorecover,
            actor,
        )
        return {
            "started": True,
            "story_id": story_id,
            "phase": _PHASE_ACT1,
            "db_latency_ms": db_latency_ms,
            "act1_s": act1_s,
            "act2_s": act2_s,
            "autorecover": autorecover,
            "postgres_deploy": postgres_deploy,
            # Operator-facing ETA so the SPA can render a "complete in
            # ~N min" hint without polling.
            "eta_s": act1_s + act2_s + (10 if autorecover else 0),
        }

    def cancel(self, actor: str) -> dict[str, Any]:
        """Cancel a running story (if any) and run recovery synchronously.

        Idempotent: safe to call when the runner is idle - it still
        runs the recovery just in case a previous run died mid-flight
        and left the cluster armed. The dispatcher's bulk recover
        endpoint also covers that case, but a defensive single-button
        clear is friendlier for the SPA UX.
        """
        with self._lock:
            currently_running = self._state.phase not in (
                _PHASE_IDLE,
                _PHASE_COMPLETE,
            )
            self._state.cancel_requested = True
            story_id = self._state.story_id or "no-run"
            postgres_deploy = self._state.postgres_deploy

        LOG.info(
            "meltdown.cancel_requested story_id=%s currently_running=%s actor=%s",
            story_id,
            currently_running,
            actor,
        )

        # Always run the recovery, even when idle, so a stale armed
        # cluster (controller restart mid-story, prior run aborted by
        # SIGTERM, ...) ends up at baseline regardless. Recovery is
        # idempotent: clearing DB_LATENCY_MS=0 when it's already 0 is
        # a no-op patch the API server collapses, and scaling postgres
        # to 1 when it's already 1 ditto.
        result = self._recover(actor=actor, story_id=story_id, reason="cancel_request")

        # Reset state so a follow-up start() works. We keep last_actor
        # around for the status() observation block.
        with self._lock:
            self._state.phase = _PHASE_IDLE
            self._state.phase_started_at = None
            self._state.cancel_requested = False
            # Don't blank story_id - the SPA shows "last run: <id>" in
            # the status pill so the operator can copy/paste it into a
            # Splunk search.

        return {
            "cancelled": True,
            "currently_running": currently_running,
            "story_id": story_id,
            "postgres_deploy": postgres_deploy,
            "recovery": result,
        }

    def status(self) -> dict[str, Any]:
        """Return the current state in the standard scenario shape.

        ``state`` is one of ``armed`` / ``clear`` / ``unknown`` so the
        SPA dashboard pill renders without a special-case.
        """
        with self._lock:
            s = self._state
            now = time.monotonic()
            elapsed_total_s = (
                int(now - s.started_at) if s.started_at is not None else 0
            )
            elapsed_phase_s = (
                int(now - s.phase_started_at)
                if s.phase_started_at is not None
                else 0
            )

            if s.phase == _PHASE_ACT1:
                remaining_s = max(0, s.act1_s - elapsed_phase_s)
                state = "armed"
            elif s.phase == _PHASE_ACT2:
                remaining_s = max(0, s.act2_s - elapsed_phase_s)
                state = "armed"
            elif s.phase == _PHASE_RECOVER:
                remaining_s = 0
                state = "armed"
            else:
                # idle or complete
                remaining_s = 0
                state = "clear"

            observed = {
                "phase": s.phase,
                "story_id": s.story_id,
                "elapsed_total_s": elapsed_total_s,
                "elapsed_phase_s": elapsed_phase_s,
                "remaining_phase_s": remaining_s,
                "db_latency_ms": s.db_latency_ms,
                "act1_s": s.act1_s,
                "act2_s": s.act2_s,
                "autorecover": s.autorecover,
                "postgres_deploy": s.postgres_deploy,
                "last_actor": s.last_actor,
            }
            if s.last_error:
                observed["last_error"] = s.last_error

        return {"state": state, "observed": observed}

    # ----- Worker thread --------------------------------------------

    def _run(self) -> None:
        """Background-thread entry point. Never call directly."""
        with self._lock:
            s = self._state
            story_id = s.story_id
            db_latency_ms = s.db_latency_ms
            act1_s = s.act1_s
            act2_s = s.act2_s
            autorecover = s.autorecover
            postgres_deploy = s.postgres_deploy
            actor = s.last_actor or "ops-dashboard"

        try:
            # ---- ACT 1 ----------------------------------------------
            self._set_phase(_PHASE_ACT1)
            LOG.info("meltdown.act1.start story_id=%s db_latency_ms=%d", story_id, db_latency_ms)
            k8s.set_env("ledger-service", {"DB_LATENCY_MS": str(db_latency_ms)})
            emit_chaos_audit(
                action="inject",
                scenario=_AUDIT_SCENARIO,
                target_service="ledger-service",
                actor=actor,
                details={
                    "story_id": story_id,
                    "act": 1,
                    "db_latency_ms": db_latency_ms,
                    **_STORY_AUDIT_CONTEXT,
                },
            )
            # Phase-level Splunk Observability event. Distinct eventType
            # (.phase rather than .inject) so the chart overlay can
            # render orchestrator phase transitions in a different
            # colour than single-act injects without conflating them.
            emit_o11y_event(
                event_type="chaos.scenario.phase",
                dimensions={
                    "scenario": _AUDIT_SCENARIO,
                    "action": "inject",
                    "service": "ledger-service",
                    "severity": "high",
                    "category": "story",
                    "phase": _PHASE_ACT1,
                },
                properties={
                    "actor": actor,
                    "story_id": story_id,
                    "act": 1,
                    "db_latency_ms": db_latency_ms,
                    "source": "chaos-controller.meltdown",
                    **_STORY_AUDIT_CONTEXT,
                },
            )
            if self._dwell(act1_s):
                LOG.info("meltdown.act1.cancelled story_id=%s", story_id)
                return  # cancel() already ran recovery

            # ---- ACT 2 ----------------------------------------------
            self._set_phase(_PHASE_ACT2)
            LOG.info(
                "meltdown.act2.start story_id=%s postgres_deploy=%s",
                story_id,
                postgres_deploy,
            )
            k8s.scale(postgres_deploy, 0)
            emit_chaos_audit(
                action="inject",
                scenario=_AUDIT_SCENARIO,
                target_service=postgres_deploy,
                actor=actor,
                details={
                    "story_id": story_id,
                    "act": 2,
                    "action": "scale_to_zero",
                    "customer_id": _STORY_AUDIT_CONTEXT["customer_id"],
                    "customer_name": _STORY_AUDIT_CONTEXT["customer_name"],
                    "payment_scheme": _STORY_AUDIT_CONTEXT["payment_scheme"],
                },
            )
            emit_o11y_event(
                event_type="chaos.scenario.phase",
                dimensions={
                    "scenario": _AUDIT_SCENARIO,
                    "action": "inject",
                    "service": postgres_deploy,
                    "severity": "high",
                    "category": "story",
                    "phase": _PHASE_ACT2,
                },
                properties={
                    "actor": actor,
                    "story_id": story_id,
                    "act": 2,
                    "k8s_action": "scale_to_zero",
                    "source": "chaos-controller.meltdown",
                },
            )
            if self._dwell(act2_s):
                LOG.info("meltdown.act2.cancelled story_id=%s", story_id)
                return

            # ---- RECOVER --------------------------------------------
            if autorecover:
                self._recover(
                    actor=actor, story_id=story_id, reason="autorecover"
                )

            with self._lock:
                self._state.phase = _PHASE_COMPLETE
                self._state.phase_started_at = None

            LOG.info("meltdown.complete story_id=%s", story_id)

        except Exception as exc:  # noqa: BLE001 - this is the background loop
            # If anything blows up we still try to recover the cluster
            # so the demo doesn't get stuck broken. The error is
            # recorded on the state so status() surfaces it on the SPA
            # card.
            LOG.exception("meltdown.error story_id=%s err=%s", story_id, exc)
            with self._lock:
                self._state.last_error = str(exc)[:200]
            self._recover(
                actor=actor, story_id=story_id, reason=f"error:{type(exc).__name__}"
            )
            with self._lock:
                self._state.phase = _PHASE_IDLE
                self._state.phase_started_at = None

    def _dwell(self, seconds: int) -> bool:
        """Sleep ``seconds`` in small ticks, returning early on cancel.

        Returns True if cancel() fired during the dwell (caller must
        stop processing - cancel() already ran recovery). Returns False
        if the dwell completed normally.
        """
        ticks = max(1, int(seconds / self._CANCEL_POLL_INTERVAL_S))
        for _ in range(ticks):
            with self._lock:
                if self._state.cancel_requested:
                    return True
            time.sleep(self._CANCEL_POLL_INTERVAL_S)
        return False

    def _set_phase(self, phase: str) -> None:
        with self._lock:
            self._state.phase = phase
            self._state.phase_started_at = time.monotonic()

    def _recover(
        self, actor: str, story_id: str, reason: str
    ) -> dict[str, Any]:
        """Restore both acts to baseline. Idempotent."""
        results: dict[str, Any] = {}
        # Always set the phase first so concurrent status() polls see
        # the transition immediately rather than racing the k8s calls.
        with self._lock:
            self._state.phase = _PHASE_RECOVER
            self._state.phase_started_at = time.monotonic()
            postgres_deploy = self._state.postgres_deploy

        # ledger DB latency back to 0. set_env is idempotent (patches
        # the deployment; identical patch = no rollout).
        try:
            results["ledger-service"] = k8s.set_env(
                "ledger-service", {"DB_LATENCY_MS": "0"}
            )
        except RuntimeError as exc:
            LOG.warning("meltdown.recover.ledger_failed err=%s", exc)
            results["ledger-service"] = {"error": str(exc)[:200]}

        # postgres back to 1. scale() is idempotent.
        try:
            results[postgres_deploy] = k8s.scale(postgres_deploy, 1)
        except RuntimeError as exc:
            LOG.warning("meltdown.recover.postgres_failed err=%s", exc)
            results[postgres_deploy] = {"error": str(exc)[:200]}

        emit_chaos_audit(
            action="clear",
            scenario=_AUDIT_SCENARIO,
            target_service="multi",
            actor=actor,
            details={
                "story_id": story_id,
                "act": "recover",
                "reason": reason,
                "results": results,
            },
        )
        emit_o11y_event(
            event_type="chaos.scenario.phase",
            dimensions={
                "scenario": _AUDIT_SCENARIO,
                "action": "clear",
                "service": "multi",
                "severity": "high",
                "category": "story",
                "phase": _PHASE_RECOVER,
            },
            properties={
                "actor": actor,
                "story_id": story_id,
                "act": "recover",
                "reason": reason,
                "results": results,
                "source": "chaos-controller.meltdown",
            },
        )
        LOG.info(
            "meltdown.recover.done story_id=%s reason=%s",
            story_id,
            reason,
        )
        return results


# Module-level singleton. scenarios.py imports this and wraps it in
# Scenario.inject / .clear / .status callables.
runner = MeltdownRunner()
