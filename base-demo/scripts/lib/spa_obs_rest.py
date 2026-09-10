#!/usr/bin/env python3
"""Create / sync the 3 SPA observability resources via the SignalFx REST API.

Driven by scripts/05e-create-spa-obs-resources.sh; runs standalone too as
long as SPLUNK_REALM and SPLUNK_API_TOKEN are exported. Mirrors what

  terraform apply \
    -target=signalfx_detector.bronze_spa_failure_rate \
    -target=signalfx_time_chart.spa_payment_outcome_by_tier \
    -target=signalfx_time_chart.spa_p95_by_network_type

would do, plus binds both new charts onto the existing
`[NatWest demo] Payments Operations` dashboard at row 12.

Provided as a fallback in case `terraform apply` is blocked. The two
known blockers are:

  1. aws_instance.splunk_enterprise.user_data validator firing on the
     ENTIRE config (not just -targeted resources) because schema
     validators run during plan regardless of -target. Cured upstream by
     splunk_enterprise.tf using user_data_base64 + base64gzip; this
     script unblocks branches older than that fix.

  2. The signalfx provider periodically rejects in-place updates to
     detectors that reference webhook integrations via
     local.obs_itsi_webhook_notifications with "invalid Webhook
     notification string ... not enough parts". Creating via REST sets
     notifications=[], which always works; wire ITSI alert-bridge
     notifications in the Splunk UI afterwards if needed.

Idempotent: each create is preceded by a search for an existing object
with the same name; if found, we PUT instead of POST so re-runs do not
duplicate. The dashboard rebind merges new chart entries into the
existing chart list rather than replacing it.

State drift caveat: when this script is used as a Terraform fallback,
Terraform does NOT know about the resources it creates. Run the three
`terraform import` lines printed at the end to bring them under
management. If you applied via Terraform first, re-running this script
is a safe no-op (PUT-on-match emits identical bodies).
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

REALM = os.environ["SPLUNK_REALM"]
TOKEN = os.environ["SPLUNK_API_TOKEN"]
API_BASE = f"https://api.{REALM}.signalfx.com"

DASHBOARD_NAME = "[NatWest demo] Payments Operations"

# Bronze SPA failure rate detector. Mirror of signalfx_detector.bronze_spa_failure_rate
# in terraform/observability.tf - all field names and values are kept
# byte-identical so a future `terraform import` lines up cleanly.
BRONZE_DETECTOR = {
    "name": "[NatWest demo] Bronze SPA failure rate",
    "description": (
        "Critical when SPA-perceived payment failure rate for Bronze customer.tier "
        "exceeds 10% for 3 minutes. Reads the payment.outcome RUM attribute from "
        "frontend/src/pages/SendMoney.tsx; fires for transport / ingress / 5xx "
        "failures the api-gateway-side detector cannot see."
    ),
    "programText": (
        "failures  = data('spans.count', filter=filter('sf_service','natwest-payments-web') and "
        "filter('sf_environment','demo') and filter('customer.tier','bronze') and "
        "filter('payment.outcome','error'), rollup='rate').sum().publish(label='failures', enable=False)\n"
        "successes = data('spans.count', filter=filter('sf_service','natwest-payments-web') and "
        "filter('sf_environment','demo') and filter('customer.tier','bronze') and "
        "filter('payment.outcome','success'), rollup='rate').sum().publish(label='successes', enable=False)\n"
        "total     = (failures + successes).publish(label='total', enable=False)\n"
        "rate      = (failures / total).fill(value=0).publish(label='bronze_spa_failure_rate')\n"
        "detect(when(rate > 0.10, lasting='3m')).publish('Bronze SPA failure rate > 10% for 3m')\n"
        "detect(when(rate > 0.05, lasting='5m') and not when(rate > 0.10, lasting='3m'))"
        ".publish('Bronze SPA failure rate > 5% for 5m')\n"
    ),
    "rules": [
        {
            "detectLabel": "Bronze SPA failure rate > 10% for 3m",
            "severity": "Critical",
            "notifications": [],
            "parameterizedBody": (
                "{{ruleSeverity}} {{ruleName}}: Bronze SPA failure rate is {{inputs.rate.value}} "
                "(>10%) - check Splunk RUM for the failing payment.completed spans "
                "(filter customer.tier=bronze, payment.outcome=error). Was inject-tier-throttle "
                "bronze run, or is the api-gateway ingress unhealthy?"
            ),
        },
        {
            "detectLabel": "Bronze SPA failure rate > 5% for 5m",
            "severity": "Warning",
            "notifications": [],
            "parameterizedBody": (
                "{{ruleSeverity}} {{ruleName}}: Bronze SPA failure rate is {{inputs.rate.value}}; "
                "trending toward critical. Cross-check the Bronze tier decline rate detector "
                "(gateway-side)."
            ),
        },
    ],
    "tags": ["natwest-demo", "payments", "tier", "rum", "spa"],
}

# spa_payment_outcome_by_tier chart. AreaChart of payment.outcome counts
# split by customer.tier, sf_service scoped to natwest-payments-web (RUM).
CHART_OUTCOME_BY_TIER = {
    "name": "SPA payment outcome by customer tier",
    "description": (
        "Customer-perceived payment funnel from RUM: payment.completed spans "
        "broken out by customer.tier and payment.outcome. The error band on "
        "Bronze widens during scripts/incident.sh inject-tier-throttle bronze."
    ),
    "programText": (
        "A = data('spans.count', filter=filter('sf_service','natwest-payments-web') and "
        "filter('sf_environment','demo') and filter('payment.outcome','*'), "
        "rollup='rate').sum(by=['customer.tier','payment.outcome']).publish(label='spa_outcome')\n"
    ),
    "options": {
        "type": "TimeSeriesChart",
        "defaultPlotType": "AreaChart",
        "axes": [{"label": "events/s", "min": 0}],
        "legendOptions": {
            "fields": [
                {"property": "customer.tier", "enabled": True},
                {"property": "payment.outcome", "enabled": True},
            ]
        },
    },
}

# spa_p95_by_network_type chart. LineChart of p95 duration of
# payment.completed spans, cohort-split by network.effective_type.
CHART_P95_BY_NETWORK = {
    "name": "SPA p95 by network.effective_type (ms)",
    "description": (
        "p95 client-perceived duration of payment.completed spans on the SPA, "
        "grouped by the browser's reported Network Information API effective_type. "
        "Cohort-splits the Madrid latency story between fast-broadband Gold users "
        "and 3G Bronze users."
    ),
    "programText": (
        "A = data('spans.duration.ns.p95', filter=filter('sf_service','natwest-payments-web') and "
        "filter('sf_environment','demo') and filter('sf_operation','payment.completed'))"
        ".mean(by=['network.effective_type']).publish(label='p95_ns', enable=False)\n"
        "B = (A / 1000000).publish(label='p95_ms')\n"
    ),
    "options": {
        "type": "TimeSeriesChart",
        "defaultPlotType": "LineChart",
        "axes": [{"label": "ms", "min": 0}],
        "legendOptions": {
            "fields": [{"property": "network.effective_type", "enabled": True}]
        },
    },
}


def _request(method: str, path: str, body: dict | None = None) -> dict:
    url = f"{API_BASE}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "X-SF-Token": TOKEN,
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        body_text = e.read().decode(errors="replace")
        raise RuntimeError(f"{method} {path} -> HTTP {e.code}: {body_text}") from None


def _find_by_name(kind: str, name: str) -> dict | None:
    """Search for a single object by exact-name match."""
    res = _request("GET", f"/v2/{kind}?name={urllib.parse.quote(name)}")
    for r in res.get("results", []):
        if r.get("name") == name:
            return r
    return None


def upsert(kind: str, payload: dict) -> dict:
    name = payload["name"]
    existing = _find_by_name(kind, name)
    if existing:
        rid = existing["id"]
        print(f"  [{kind}] update existing id={rid} name={name!r}")
        return _request("PUT", f"/v2/{kind}/{rid}", payload)
    print(f"  [{kind}] create new name={name!r}")
    return _request("POST", f"/v2/{kind}", payload)


def main() -> int:
    print(f"SignalFx API base: {API_BASE}")
    print(f"Token length:      {len(TOKEN)}")

    print("\n[1/4] Bronze SPA failure rate detector")
    detector = upsert("detector", BRONZE_DETECTOR)
    print(f"        id={detector['id']}")

    print("\n[2/4] SPA payment outcome by customer tier (chart)")
    chart_outcome = upsert("chart", CHART_OUTCOME_BY_TIER)
    print(f"        id={chart_outcome['id']}")

    print("\n[3/4] SPA p95 by network.effective_type (chart)")
    chart_p95 = upsert("chart", CHART_P95_BY_NETWORK)
    print(f"        id={chart_p95['id']}")

    print(f"\n[4/4] Bind charts onto dashboard {DASHBOARD_NAME!r}")
    dash = _find_by_name("dashboard", DASHBOARD_NAME)
    if not dash:
        print(f"  ERROR: dashboard not found by name. List of dashboards:")
        all_dash = _request("GET", "/v2/dashboard?limit=200")
        for d in all_dash.get("results", []):
            print(f"    - {d.get('id')}: {d.get('name')!r}")
        return 1
    dash_id = dash["id"]
    print(f"  dashboard id={dash_id}")

    # Re-fetch full dashboard so we get the chart list (search results don't
    # always include 'charts').
    full = _request("GET", f"/v2/dashboard/{dash_id}")
    existing_charts = full.get("charts", []) or []
    existing_chart_ids = {c.get("chartId") for c in existing_charts}
    print(f"  existing chart bindings: {len(existing_charts)}")

    new_bindings = []
    for chart_id, column in ((chart_outcome["id"], 0), (chart_p95["id"], 6)):
        if chart_id in existing_chart_ids:
            print(f"    skip {chart_id} (already bound)")
            continue
        new_bindings.append({
            "chartId": chart_id,
            "row": 12,
            "column": column,
            "width": 6,
            "height": 3,
        })

    if not new_bindings:
        print("  nothing to bind")
        return 0

    full["charts"] = existing_charts + new_bindings
    _request("PUT", f"/v2/dashboard/{dash_id}", full)
    print(f"  bound {len(new_bindings)} new chart(s) at row=12")

    print("\nDone. Resources are live in Splunk Observability.")
    print(f"  detector: https://app.{REALM}.signalfx.com/#/detector/v2/{detector['id']}/edit")
    print(f"  dashboard: https://app.{REALM}.signalfx.com/#/dashboard/{dash_id}")
    print()
    print("STATE DRIFT NOTE: Terraform does not know about these resources.")
    print("After the aws_instance.user_data blocker is fixed, run:")
    print(f"  terraform import signalfx_detector.bronze_spa_failure_rate '{detector['id']}'")
    print(f"  terraform import signalfx_time_chart.spa_payment_outcome_by_tier '{chart_outcome['id']}'")
    print(f"  terraform import signalfx_time_chart.spa_p95_by_network_type '{chart_p95['id']}'")
    return 0


if __name__ == "__main__":
    sys.exit(main())
