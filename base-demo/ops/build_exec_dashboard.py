#!/usr/bin/env python3
"""Build 'NatWest Payments — Executive View' in Craig's dashboard group.
Charts reuse SignalFlow programs proven by Marc's terraform (same org metrics).
"""
import json, urllib.request, sys

import os; TOKEN = os.environ.get("SFX_API_TOKEN") or open(os.path.join(os.path.dirname(__file__), "../secrets/observability.env")).read().split("SFX_API_TOKEN=")[1].strip()
API = "https://api.eu0.signalfx.com/v2"
GROUP = "HLKcs21AIAY"
ENV = "filter('sf_environment','demo')"
GW = f"filter('sf_service','api-gateway') and {ENV}"
INIT = f"filter('sf_service','payment-initiation-service') and {ENV}"
SPA = f"filter('sf_service','natwest-payments-web') and {ENV}"

def req(path, body=None, method="GET"):
    r = urllib.request.Request(API + path, method=method,
        headers={"X-SF-TOKEN": TOKEN, "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body else None)
    try:
        with urllib.request.urlopen(r) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        print("API ERROR", e.code, path, ":", e.read().decode()[:400])
        sys.exit(1)

def chart(name, program, opts):
    import urllib.parse
    existing = req("/chart?name=" + urllib.parse.quote(name) + "&limit=50")
    for r in existing.get("results", []):
        if r.get("name") == name:
            print("chart (reused):", r["id"], name)
            return r["id"]
    c = req("/chart", {"name": name, "programText": program, "options": opts}, "POST")
    print("chart:", c["id"], name)
    return c["id"]

TS = lambda plot="LineChart": {"type": "TimeSeriesChart", "defaultPlotType": plot,
    "legendOptions": {"fields": []}}
SV = {"type": "SingleValue", "unitPrefix": "Metric"}
LIST = {"type": "List", "sortBy": "-value"}

charts = []  # (id, row, col, w, h)

# ---- Row 0: exec KPI band -------------------------------------------------
cid = chart("Payments per second",
    f"A = data('spans.count', filter={GW}, rollup='rate').sum().publish(label='pps')", SV)
charts.append((cid, 0, 0, 2, 1))

cid = chart("GBP volume processed",
    f"A = data('spans.payment.amount_minor_units', filter={GW} and filter('payment.currency','GBP') and filter('sf_error','false')).sum().publish(label='m', enable=False)\n"
    "B = (A / 100).publish(label='GBP')", SV)
charts.append((cid, 0, 2, 2, 1))

cid = chart("Decline rate %",
    f"errors = data('spans.count', filter={GW} and filter('sf_error','true'), rollup='rate').sum().publish(label='e', enable=False)\n"
    f"total = data('spans.count', filter={GW}, rollup='rate').sum().publish(label='t', enable=False)\n"
    "rate = (errors / total * 100).fill(value=0).publish(label='decline_pct')", SV)
charts.append((cid, 0, 4, 3, 1))

cid = chart("Customer conversion %",
    f"ok = data('spans.count', filter={SPA} and filter('payment.outcome','success'), rollup='rate').sum().publish(label='ok', enable=False)\n"
    f"all = data('spans.count', filter={SPA} and filter('payment.outcome','*'), rollup='rate').sum().publish(label='all', enable=False)\n"
    "conv = (ok / all * 100).fill(value=0).publish(label='conversion_pct')", SV)
charts.append((cid, 0, 7, 3, 1))

cid = chart("p99 payment latency (ms)",
    f"A = data('spans.duration.ns.p99', filter={INIT}).mean().publish(label='ns', enable=False)\n"
    "B = (A / 1000000).publish(label='p99_ms')", SV)
charts.append((cid, 0, 10, 2, 1))

# ---- Row 1: flow headers ---------------------------------------------------
for i, (title, sub) in enumerate([
    ("&#10122; CUSTOMER EXPERIENCE", "what customers see — the SPA"),
    ("&#10123; PAYMENT GATEWAY &amp; FLOW", "traffic entering the platform"),
    ("&#10124; RISK &amp; PROCESSING", "screening, declines, downstream")]):
    cid = chart(f"hdr{i}", "", {"type": "Text",
        "markdown": f"### {title}\n{sub}"})
    charts.append((cid, 1, i * 4, 4, 1))

# ---- Row 2 ------------------------------------------------------------------
cid = chart("SPA payment outcome by tier",
    f"A = data('spans.count', filter={SPA} and filter('payment.outcome','*'), rollup='rate').sum(by=['customer.tier','payment.outcome']).publish(label='outcome')",
    TS("AreaChart"))
charts.append((cid, 2, 0, 4, 2))

cid = chart("Payment rate by scheme",
    f"A = data('spans.count', filter={GW}, rollup='rate').sum(by=['payment.scheme']).publish(label='RPS')",
    TS("AreaChart"))
charts.append((cid, 2, 4, 4, 2))

cid = chart("Error rate by country corridor",
    f"errors = data('spans.count', filter={GW} and filter('sf_error','true'), rollup='rate').sum(by=['payment.country_pair']).publish(label='e', enable=False)\n"
    f"total = data('spans.count', filter={GW}, rollup='rate').sum(by=['payment.country_pair']).publish(label='t', enable=False)\n"
    "rate = (errors / total).fill(value=0).publish(label='error_rate')", TS())
charts.append((cid, 2, 8, 4, 2))

# ---- Row 3 ------------------------------------------------------------------
cid = chart("SPA p95 by network type (ms)",
    f"A = data('spans.duration.ns.p95', filter={SPA} and filter('sf_operation','payment.completed')).mean(by=['network.effective_type']).publish(label='ns', enable=False)\n"
    "B = (A / 1000000).publish(label='p95_ms')", TS())
charts.append((cid, 3, 0, 4, 2))

cid = chart("p95 latency by city (ms) — Madrid watch",
    f"A = data('spans.duration.ns.p95', filter={GW}).mean(by=['customer.location']).publish(label='ns', enable=False)\n"
    "B = (A / 1000000).publish(label='p95_ms')", TS())
charts.append((cid, 3, 4, 4, 2))

cid = chart("Decline + throttle rate by tier",
    f"declines = data('spans.count', filter={GW} and filter('sf_error','true'), rollup='rate').sum(by=['customer.tier']).publish(label='d', enable=False)\n"
    f"total = data('spans.count', filter={GW}, rollup='rate').sum(by=['customer.tier']).publish(label='t', enable=False)\n"
    "rate = (declines / total).fill(value=0).publish(label='decline_rate')", TS())
charts.append((cid, 3, 8, 4, 2))

# ---- Row 4 ------------------------------------------------------------------
cid = chart("Customer tier mix (exec)",
    f"A = data('spans.count', filter={GW}, rollup='rate').sum(by=['customer.tier']).publish(label='tier_mix')", LIST)
charts.append((cid, 5, 0, 4, 2))

cid = chart("Cache hit ratio by namespace (exec)",
    f"hits = data('spans.count', filter={ENV} and filter('cache.hit','true'), rollup='rate').sum(by=['cache.namespace']).publish(label='h', enable=False)\n"
    f"total = data('spans.count', filter={ENV} and filter('cache.namespace','*'), rollup='rate').sum(by=['cache.namespace']).publish(label='t', enable=False)\n"
    "ratio = (hits / total).fill(value=0).publish(label='hit_ratio')", TS())
charts.append((cid, 5, 4, 4, 2))

cid = chart("Slowest payment operations",
    f"A = data('spans.duration.ns.p99', filter={INIT}).mean(by=['sf_operation']).publish(label='p99_ns')", LIST)
charts.append((cid, 5, 8, 4, 2))

# ---- Dashboard ---------------------------------------------------------------
dash = req("/dashboard", {
    "name": "NatWest Payments — Executive View",
    "groupId": GROUP,
    "description": "Exec overview: business KPIs top, payment flow left-to-right below. Built from APM/RUM metric sets. Companion to the ITSI Service Intelligence glass table.",
    "charts": [{"chartId": c, "row": r, "column": col, "width": w, "height": h}
               for c, r, col, w, h in charts],
}, "POST")
print("DASHBOARD:", dash["id"])
print(f"URL: https://app.eu0.signalfx.com/#/dashboard/{dash['id']}")
