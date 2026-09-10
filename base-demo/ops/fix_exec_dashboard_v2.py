#!/usr/bin/env python3
"""Exec dashboard v2: constrain everything to true payment journeys
(filter on the custom tag selects only tag-bearing MetricSets), explicit
outcome sets, 'journeys' labels, drop impossible dims."""
import json, urllib.request, sys

TOKEN = open("/tmp/sfx_token_run").read().strip()
API = "https://api.eu0.signalfx.com/v2"
DASH = "HNLjM2GAAAA"
GW = "filter('sf_service','api-gateway') and filter('sf_environment','demo')"
PAY = f"{GW} and filter('payment.scheme','*')"                      # payment journeys
OUT = f"{GW} and filter('payment.outcome','success','partial','error')"
RUMAPP = "filter('app','natwest-payments-web')"

def req(path, body=None, method="GET"):
    r = urllib.request.Request(API + path, method=method,
        headers={"X-SF-TOKEN": TOKEN, "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body else None)
    try:
        with urllib.request.urlopen(r) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        print("API ERROR", e.code, path, ":", e.read().decode()[:300]); sys.exit(1)

SV = {"type": "SingleValue", "unitPrefix": "Metric"}
TSA = {"type": "TimeSeriesChart", "defaultPlotType": "AreaChart", "legendOptions": {"fields": []}}
TSL = {"type": "TimeSeriesChart", "defaultPlotType": "LineChart", "legendOptions": {"fields": []}}

REWRITES = {
 "Payments per minute": ("Payment journeys per minute",
    f"A = histogram('spans', filter={PAY}).count(by=['payment.scheme']).publish(label='by_scheme', enable=False)\n"
    "B = A.sum().publish(label='journeys')", SV),
 "Madrid p95 latency (ms)": ("Madrid p95 latency (ms)",
    f"A = histogram('spans', filter={GW} and filter('customer.location','madrid')).percentile(pct=95).publish(label='ns', enable=False)\n"
    "B = (A / 1000000).publish(label='madrid_p95_ms')", SV),
 "Decline rate %": ("Decline rate %",
    f"d = histogram('spans', filter={GW} and filter('payment.outcome','partial','error')).count().publish(label='d', enable=False)\n"
    f"t = histogram('spans', filter={OUT}).count().publish(label='t', enable=False)\n"
    "r = (d / t * 100).fill(value=0).publish(label='decline_pct')", SV),
 "Customer conversion %": ("Customer conversion %",
    f"ok = histogram('spans', filter={GW} and filter('payment.outcome','success')).count().publish(label='ok', enable=False)\n"
    f"t = histogram('spans', filter={OUT}).count().publish(label='t', enable=False)\n"
    "c = (ok / t * 100).fill(value=0).publish(label='conversion_pct')", SV),
 "p99 payment latency (ms)": ("p99 payment latency (ms)",
    f"A = histogram('spans', filter={PAY}).percentile(pct=99).publish(label='ns', enable=False)\n"
    "B = (A / 1000000).publish(label='p99_ms')", SV),
 "Payment outcome by customer tier": ("Payment outcome — success vs declined",
    f"A = histogram('spans', filter={OUT}).count(by=['payment.outcome']).publish(label='journeys')", TSA),
 "Payment rate by scheme": ("Payment rate by scheme",
    f"A = histogram('spans', filter={PAY}).count(by=['payment.scheme']).publish(label='journeys')", TSA),
 "Error rate by country corridor": ("Error rate by scheme",
    f"e = histogram('spans', filter={PAY} and filter('sf_error','true')).count(by=['payment.scheme']).publish(label='e', enable=False)\n"
    f"t = histogram('spans', filter={PAY}).count(by=['payment.scheme']).publish(label='t', enable=False)\n"
    "r = (e / t).fill(value=0).publish(label='error_rate')", TSL),
 "p95 latency by city (ms) — Madrid watch": ("p95 latency by city (ms)",
    f"A = histogram('spans', filter={GW} and filter('customer.location','*')).percentile(pct=95, by=['customer.location']).publish(label='ns', enable=False)\n"
    "B = (A / 1000000).publish(label='p95_ms')", TSL),
 "Decline rate by customer tier": ("p95 latency by customer tier (ms)",
    f"A = histogram('spans', filter={GW} and filter('customer.tier','*')).percentile(pct=95, by=['customer.tier']).publish(label='ns', enable=False)\n"
    "B = (A / 1000000).publish(label='p95_ms')", TSL),
 "Customer tier mix": ("Customer tier mix",
    f"A = histogram('spans', filter={GW} and filter('customer.tier','*')).count(by=['customer.tier']).publish(label='journeys')", None),
}

dash = req(f"/dashboard/{DASH}")
for entry in dash.get("charts", []):
    c = req(f"/chart/{entry['chartId']}")
    name = c.get("name")
    if name not in REWRITES:
        continue
    new_name, program, opts = REWRITES[name]
    req(f"/chart/{c['id']}", {"name": new_name, "programText": program,
        "options": opts if opts else c.get("options")}, "PUT")
    print(f"updated: {name} -> {new_name}")
print("done")
