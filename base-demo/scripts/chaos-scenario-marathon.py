#!/usr/bin/env python3
"""Run every chaos scenario for a fixed dwell time and record outcomes.

Injects each deployed scenario, waits DWELL_S (default 1200 = 20 min),
samples Splunk trace metrics, clears the scenario, then moves on.
Writes JSON + Markdown under docs/operations/.

Usage:
  python3 scripts/chaos-scenario-marathon.py
  DWELL_S=300 python3 scripts/chaos-scenario-marathon.py   # shorter test
"""

from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = REPO_ROOT / "docs" / "operations"
JSON_OUT = OUT_DIR / "chaos-scenario-test-results.json"
MD_OUT = OUT_DIR / "chaos-scenario-test-results.md"

DWELL_S = int(os.environ.get("DWELL_S", "1200"))
SETTLE_S = int(os.environ.get("SETTLE_S", "120"))
SAMPLE_INTERVAL_S = int(os.environ.get("SAMPLE_INTERVAL_S", "300"))
MARATHON_LIMIT = int(os.environ.get("MARATHON_LIMIT", "0"))  # 0 = all scenarios

SPLUNK_HOST = os.environ.get("SPLUNK_ENTERPRISE_HOST", "itsi.splunk-observability.com")
SPLUNK_USER = os.environ.get("SPLUNK_USER", "admin")
SPLUNK_PASS = os.environ.get(
    "TF_VAR_splunk_enterprise_admin_password",
    os.environ.get("SPLUNK_PASS", "smartway"),
)
NS = os.environ.get("SERVICE_NAMESPACE", "natwest")

# Least-disruptive first; heavy infra outages last.
SCENARIO_ORDER = [
    "latency-creep",
    "madrid-network-degradation",
    "fraud-cpu-regression",
    "gold-fast-path-off",
    "tier-throttle",
    "cache-cold",
    "sanctions-cache-disabled",
    "bad-deploy-fraud",
    "swift-counterparty-flap",
    "swift-scheme-outage",
    "db-slow",
    "gateway-timeout-squeeze",
    "settlement-producer-off",
    "pod-restart-gateway",
    "kill-service",
    "bad-deploy-payment-initiation",
    "redis-outage",
    "kafka-outage",
    "postgres-outage",
]

# Override inject bodies where defaults are too destructive for a marathon.
INJECT_OVERRIDES: dict[str, dict[str, Any]] = {
    "kill-service": {"service": "payment-status-service"},
    "tier-throttle": {"tier": "gold"},
}

SKIP_IDS = frozenset({"apm-topology-repair", "traffic-steady-state", "payment-meltdown"})


@dataclass
class Sample:
    at_s: int
    gateway_5xx_pct: float | None
    gateway_requests: int | None
    target_errors: int | None
    target_traces: int | None
    target_p95_ms: float | None
    pods_ready: str | None


@dataclass
class ScenarioResult:
    id: str
    name: str
    category: str
    severity: str
    target_service: str
    inject_ok: bool
    inject_response: dict[str, Any] | str
    clear_ok: bool
    clear_response: dict[str, Any] | str
    status_after_inject: dict[str, Any]
    status_after_clear: dict[str, Any]
    started_at: str
    ended_at: str
    dwell_s: int
    samples: list[Sample] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    outcome: str = "pending"  # pass | warn | fail


def _ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _kubectl(args: list[str]) -> str:
    try:
        return subprocess.check_output(
            ["kubectl", "-n", NS, *args],
            stderr=subprocess.STDOUT,
            text=True,
            timeout=60,
        ).strip()
    except subprocess.CalledProcessError as exc:
        return f"error: {exc.output.strip()}"


def _splunk_count(spl: str) -> int:
    body = urllib.parse.urlencode(
        {
            "search": f"search {spl}",
            "output_mode": "json",
            "exec_mode": "oneshot",
        }
    ).encode()
    url = f"https://{SPLUNK_HOST}:8089/services/search/jobs/export"
    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Authorization": "Basic "
            + base64.b64encode(f"{SPLUNK_USER}:{SPLUNK_PASS}".encode()).decode()
        },
    )
    ctx = urllib.request.ssl._create_unverified_context()  # noqa: SLF001
    with urllib.request.urlopen(req, context=ctx, timeout=180) as resp:
        for raw in resp:
            line = raw.decode().strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            result = row.get("result")
            if not result:
                continue
            val = result.get("count", "0")
            try:
                return int(float(val))
            except (TypeError, ValueError):
                return 0
    return 0


def _splunk_scalar(spl: str, field: str = "value") -> float | None:
    body = urllib.parse.urlencode(
        {
            "search": f"search {spl}",
            "output_mode": "json",
            "exec_mode": "oneshot",
        }
    ).encode()
    url = f"https://{SPLUNK_HOST}:8089/services/search/jobs/export"
    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Authorization": "Basic "
            + base64.b64encode(f"{SPLUNK_USER}:{SPLUNK_PASS}".encode()).decode()
        },
    )
    ctx = urllib.request.ssl._create_unverified_context()  # noqa: SLF001
    with urllib.request.urlopen(req, context=ctx, timeout=180) as resp:
        for raw in resp:
            line = raw.decode().strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            result = row.get("result")
            if not result:
                continue
            val = result.get(field)
            if val is None:
                return None
            try:
                return float(val)
            except (TypeError, ValueError):
                return None
    return None


def _service_from_target(target: str) -> str | None:
    if not target or target in ("(parameterised)", "multi"):
        return None
    return target.split("+")[0].strip()


def _sample_metrics(target_service: str, window_m: int = 5) -> Sample:
    svc = _service_from_target(target_service)
    gw_spl = (
        f'index=otel_traces sourcetype="otel:traces" earliest=-{window_m}m '
        "service.name=api-gateway "
        "| stats count as total "
        "count(eval(attributes.error=true OR tonumber(coalesce(attributes.http.status_code,'0'))>=500)) as err "
        "| eval pct=if(total>0, round(100*err/total,2), 0) "
        "| fields pct total"
    )
    gw_pct = _splunk_scalar(
        gw_spl + " | rename pct as value", "value"
    )
    gw_total = _splunk_scalar(
        gw_spl + " | rename total as value", "value"
    )

    target_errors = None
    target_traces = None
    target_p95 = None
    if svc:
        target_traces = _splunk_count(
            f'index=otel_traces sourcetype="otel:traces" earliest=-{window_m}m '
            f"service.name={svc} | stats count"
        )
        target_errors = _splunk_count(
            f'index=otel_traces sourcetype="otel:traces" earliest=-{window_m}m '
            f"service.name={svc} attributes.error=true | stats count"
        )
        target_p95 = _splunk_scalar(
            f'index=otel_traces sourcetype="otel:traces" earliest=-{window_m}m '
            f"service.name={svc} "
            "| stats perc95(duration_nanoseconds) as value",
            "value",
        )
        if target_p95 is None:
            target_p95 = _splunk_scalar(
                f'index=otel_traces sourcetype="otel:traces" earliest=-{window_m}m '
                f"service.name={svc} "
                "| stats perc95(duration) as value",
                "value",
            )
        if target_p95 is not None and target_p95 > 100_000:
            target_p95 = round(target_p95 / 1_000_000, 1)  # ns -> ms
        elif target_p95 is not None:
            target_p95 = round(target_p95, 1)

    deploy = svc or ""
    pods_ready = None
    if deploy and _kubectl(["get", "deploy", deploy, "--ignore-not-found"]):
        pods_ready = _kubectl(
            [
                "get",
                "deploy",
                deploy,
                "-o",
                "jsonpath={.status.readyReplicas}/{.spec.replicas}",
            ]
        )

    return Sample(
        at_s=0,
        gateway_5xx_pct=gw_pct,
        gateway_requests=int(gw_total) if gw_total is not None else None,
        target_errors=target_errors,
        target_traces=target_traces,
        target_p95_ms=target_p95,
        pods_ready=pods_ready,
    )


class ChaosClient:
    def __init__(self, base_url: str, token: str) -> None:
        self.base = base_url.rstrip("/")
        self.token = token

    def _request(
        self, method: str, path: str, body: dict[str, Any] | None = None
    ) -> tuple[bool, Any]:
        data = None
        headers = {"X-Chaos-Token": self.token}
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(
            f"{self.base}{path}",
            data=data,
            method=method,
            headers=headers,
        )
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                raw = resp.read().decode()
                return True, json.loads(raw) if raw else {}
        except urllib.error.HTTPError as exc:
            try:
                detail = exc.read().decode()
            except Exception:
                detail = str(exc)
            return False, detail
        except Exception as exc:
            return False, str(exc)

    def scenarios(self) -> list[dict[str, Any]]:
        ok, data = self._request("GET", "/chaos/api/scenarios")
        if not ok:
            raise RuntimeError(f"failed to list scenarios: {data}")
        return data.get("scenarios", data)

    def inject(self, scenario_id: str, body: dict[str, Any]) -> tuple[bool, Any]:
        return self._request("POST", f"/chaos/api/{scenario_id}/inject", body)

    def clear(self, scenario_id: str) -> tuple[bool, Any]:
        return self._request("POST", f"/chaos/api/{scenario_id}/clear", {})

    def recover(self) -> tuple[bool, Any]:
        return self._request("POST", "/chaos/api/recover", {})

    def status_from_catalog(self, scenario: dict[str, Any]) -> dict[str, Any]:
        return scenario.get("status", {})


def _resolve_chaos_client() -> ChaosClient:
    token = os.environ.get("CHAOS_PRESENTER_TOKEN", "")
    if not token:
        token = subprocess.check_output(
            [
                "kubectl",
                "-n",
                NS,
                "get",
                "secret",
                "chaos-controller-token",
                "-o",
                "jsonpath={.data.CHAOS_PRESENTER_TOKEN}",
            ],
            text=True,
        ).strip()
        if token:
            import base64 as b64

            token = b64.b64decode(token).decode()
    spa = os.environ.get("SPA_URL", "")
    if not spa:
        spa = subprocess.check_output(
            [
                "terraform",
                f"-chdir={REPO_ROOT / 'terraform'}",
                "output",
                "-raw",
                "public_spa_url",
            ],
            text=True,
        ).strip()
    if not token or not spa:
        raise RuntimeError("need CHAOS_PRESENTER_TOKEN and SPA_URL")
    return ChaosClient(spa, token)


def _inject_body(scenario: dict[str, Any]) -> dict[str, Any]:
    sid = scenario["id"]
    if sid in INJECT_OVERRIDES:
        return dict(INJECT_OVERRIDES[sid])
    param = scenario.get("param")
    if not param:
        return {}
    name = param.get("name")
    default = param.get("default")
    if name and default is not None:
        return {name: default}
    return {}


def _classify_outcome(result: ScenarioResult) -> str:
    if not result.inject_ok or not result.clear_ok:
        return "fail"
    last = result.samples[-1] if result.samples else None
    if last and last.gateway_5xx_pct is not None and last.gateway_5xx_pct >= 15:
        return "pass"  # strong symptom at gateway
    if last and last.target_errors and last.target_traces:
        err_pct = 100 * last.target_errors / max(last.target_traces, 1)
        if err_pct >= 5 or (last.target_p95_ms and last.target_p95_ms >= 500):
            return "pass"
    if result.status_after_inject.get("state") == "armed":
        return "pass"
    if result.notes:
        return "warn"
    return "warn"


def _run_scenario(client: ChaosClient, scenario: dict[str, Any]) -> ScenarioResult:
    sid = scenario["id"]
    body = _inject_body(scenario)
    result = ScenarioResult(
        id=sid,
        name=scenario.get("name", sid),
        category=scenario.get("category", ""),
        severity=scenario.get("severity", ""),
        target_service=scenario.get("target_service", ""),
        inject_ok=False,
        inject_response={},
        clear_ok=False,
        clear_response={},
        status_after_inject={},
        status_after_clear={},
        started_at=_ts(),
        ended_at="",
        dwell_s=DWELL_S,
    )

    print(f"\n=== [{_ts()}] INJECT {sid} body={body} ===", flush=True)
    ok, resp = client.inject(sid, body)
    result.inject_ok = ok
    result.inject_response = resp
    if not ok:
        result.notes.append(f"inject failed: {resp}")
        result.ended_at = _ts()
        result.outcome = "fail"
        return result

    time.sleep(30)
    catalog = {s["id"]: s for s in client.scenarios()}
    result.status_after_inject = catalog.get(sid, {}).get("status", {})

    elapsed = 0
    while elapsed < DWELL_S:
        sleep_s = min(SAMPLE_INTERVAL_S, DWELL_S - elapsed)
        time.sleep(sleep_s)
        elapsed += sleep_s
        sample = _sample_metrics(result.target_service, window_m=max(5, sleep_s // 60))
        sample.at_s = elapsed
        result.samples.append(sample)
        print(
            f"  sample @{elapsed}s: gw_5xx={sample.gateway_5xx_pct}% "
            f"target_err={sample.target_errors} p95={sample.target_p95_ms}ms "
            f"pods={sample.pods_ready}",
            flush=True,
        )

    print(f"=== [{_ts()}] CLEAR {sid} ===", flush=True)
    ok, resp = client.clear(sid)
    result.clear_ok = ok
    result.clear_response = resp
    if not ok:
        result.notes.append(f"clear failed: {resp}")

    time.sleep(SETTLE_S)
    catalog = {s["id"]: s for s in client.scenarios()}
    result.status_after_clear = catalog.get(sid, {}).get("status", {})
    if result.status_after_clear.get("state") not in ("clear", "unknown", None):
        result.notes.append(f"state after clear: {result.status_after_clear.get('state')}")

    result.ended_at = _ts()
    result.outcome = _classify_outcome(result)
    return result


def _render_markdown(run_meta: dict[str, Any], results: list[ScenarioResult]) -> str:
    lines = [
        "# Chaos scenario marathon results",
        "",
        f"**Run started:** {run_meta['started_at']}  ",
        f"**Run ended:** {run_meta['ended_at']}  ",
        f"**Dwell per scenario:** {run_meta['dwell_s']}s ({run_meta['dwell_s'] // 60} min)  ",
        f"**Scenarios tested:** {len(results)}  ",
        "",
        "## Summary",
        "",
        "| Outcome | Count |",
        "|---------|-------|",
    ]
    for outcome in ("pass", "warn", "fail"):
        n = sum(1 for r in results if r.outcome == outcome)
        lines.append(f"| {outcome} | {n} |")

    lines.extend(["", "## Results by scenario", ""])
    for r in results:
        lines.append(f"### {r.name} (`{r.id}`)")
        lines.append("")
        lines.append(f"- **Category:** {r.category} | **Severity:** {r.severity}")
        lines.append(f"- **Target:** {r.target_service}")
        lines.append(f"- **Outcome:** {r.outcome}")
        lines.append(f"- **Window:** {r.started_at} → {r.ended_at}")
        lines.append(
            f"- **Inject:** {'OK' if r.inject_ok else 'FAILED'} | "
            f"**Clear:** {'OK' if r.clear_ok else 'FAILED'}"
        )
        lines.append(
            f"- **Status:** inject={r.status_after_inject.get('state', '?')} → "
            f"clear={r.status_after_clear.get('state', '?')}"
        )
        if r.samples:
            last = r.samples[-1]
            lines.append(
                f"- **Final sample (5m window):** gateway 5xx={last.gateway_5xx_pct}%, "
                f"target errors={last.target_errors}/{last.target_traces}, "
                f"target p95={last.target_p95_ms}ms, pods={last.pods_ready}"
            )
        if r.notes:
            lines.append(f"- **Notes:** {'; '.join(r.notes)}")
        lines.append("")

    lines.extend(
        [
            "## Observations",
            "",
            "Metrics are sampled from `index=otel_traces` on Splunk Enterprise. "
            "A **pass** means inject/clear succeeded and trace data showed elevated "
            "errors, latency, or an armed scenario state during the dwell window. "
            "**warn** usually means the scenario ran but symptoms were subtle in the "
            "5-minute Splunk lookback (e.g. transient pod restarts). **fail** means "
            "inject or clear did not complete.",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    client = _resolve_chaos_client()
    catalog = {s["id"]: s for s in client.scenarios()}

    ordered_ids = [sid for sid in SCENARIO_ORDER if sid in catalog and sid not in SKIP_IDS]
    extra = [sid for sid in catalog if sid not in ordered_ids and sid not in SKIP_IDS]
    ordered_ids.extend(sorted(extra))
    if MARATHON_LIMIT > 0:
        ordered_ids = ordered_ids[:MARATHON_LIMIT]

    run_meta = {
        "started_at": _ts(),
        "ended_at": "",
        "dwell_s": DWELL_S,
        "settle_s": SETTLE_S,
        "scenario_ids": ordered_ids,
    }

    print(f"Recovering baseline before marathon ({len(ordered_ids)} scenarios)...", flush=True)
    client.recover()
    time.sleep(90)

    results: list[ScenarioResult] = []
    for i, sid in enumerate(ordered_ids, 1):
        scenario = catalog[sid]
        print(f"\n######## Scenario {i}/{len(ordered_ids)}: {sid} ########", flush=True)
        try:
            result = _run_scenario(client, scenario)
        except Exception as exc:
            result = ScenarioResult(
                id=sid,
                name=scenario.get("name", sid),
                category=scenario.get("category", ""),
                severity=scenario.get("severity", ""),
                target_service=scenario.get("target_service", ""),
                inject_ok=False,
                inject_response=str(exc),
                clear_ok=False,
                clear_response="",
                status_after_inject={},
                status_after_clear={},
                started_at=_ts(),
                ended_at=_ts(),
                dwell_s=DWELL_S,
                notes=[f"exception: {exc}"],
                outcome="fail",
            )
        results.append(result)
        # Persist incrementally so a long run is not lost.
        run_meta["ended_at"] = _ts()
        payload = {"run": run_meta, "results": [asdict(r) for r in results]}
        JSON_OUT.write_text(json.dumps(payload, indent=2))
        MD_OUT.write_text(_render_markdown(run_meta, results))

    print(f"\nDone. Wrote {JSON_OUT} and {MD_OUT}", flush=True)
    print("Running final recover-all...", flush=True)
    client.recover()
    failed = sum(1 for r in results if r.outcome == "fail")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
