#!/usr/bin/env python3
"""Rewrite the exec dashboard's charts onto histogram MetricSets + RUM MMS
(the org migrated custom span tags to histogram('spans'); old spans.count
programs with custom dims return nothing)."""
import json, urllib.request, sys

TOKEN = open("/tmp/sfx_token_run").read().strip()
API = "https://api.eu0.signalfx.com/v2"
DASH = "HNLjM2GAAAA"
GW = "filter('sf_service','api-gateway') and filter('sf_environment','demo')"
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

# name -> (new_name, programText, options_override or None)
SV = {"type": "SingleValue", "unitPrefix": "Metric"}
TSA = {"type": "TimeSeriesChart", "defaultPlotType": "AreaChart", "legendOptions": {"fields": []}}
TSL = {"type": "TimeSeriesChart", "defaultPlotType": "LineChart", "legendOptions": {"fields": []}}

REWRITES = {
 "Payments per second": ("Payments per minute",
    f"A = histogram('spans', filter={GW}).count().publish(label='payments')", SV),
 "GBP volume processed": ("Madrid p95 latency (ms)",
    f"A = histogram('spans', filter={GW} and filter('customer.location','madrid')).percentile(pct=95).publish(label='ns', enable=False)\n"
    "B = (A / 1000000).publish(label='madrid_p95_ms')", SV),
 "Decline rate %": ("Decline rate %",
    f"d = histogram('spans', filter={GW} and filter('payment.outcome','partial','error')).count().publish(label='d', enable=False)\n"
    f"t = histogram('spans', filter={GW} and filter('payment.outcome','*')).count().publish(label='t', enable=False)\n"
    "r = (d / t * 100).fill(value=0).publish(label='decline_pct')", SV),
 "Customer conversion %": ("Customer conversion %",
    f"ok = histogram('spans', filter={GW} and filter('payment.outcome','success')).count().publish(label='ok', enable=False)\n"
    f"t = histogram('spans', filter={GW} and filter('payment.outcome','*')).count().publish(label='t', enable=False)\n"
    "c = (ok / t * 100).fill(value=0).publish(label='conversion_pct')", SV),
 "p99 payment latency (ms)": ("p99 payment latency (ms)",
    f"A = histogram('spans', filter={GW}).percentile(pct=99).publish(label='ns', enable=False)\n"
    "B = (A / 1000000).publish(label='p99_ms')", SV),
 "SPA payment outcome by tier": ("Payment outcome by customer tier",
    f"A = histogram('spans', filter={GW} and filter('payment.outcome','*')).count(by=['customer.tier','payment.outcome']).publish(label='outcome')", TSA),
 "Payment rate by scheme": ("Payment rate by scheme",
    f"A = histogram('spans', filter={GW}).count(by=['payment.scheme']).publish(label='payments')", TSA),
 "Error rate by country corridor": ("Error rate by country corridor",
    f"e = histogram('spans', filter={GW} and filter('sf_error','true')).count(by=['payment.country_pair']).publish(label='e', enable=False)\n"
    f"t = histogram('spans', filter={GW}).count(by=['payment.country_pair']).publish(label='t', enable=False)\n"
    "r = (e / t).fill(value=0).publish(label='error_rate')", TSL),
 "SPA p95 by network type (ms)": ("Page load p75 by city (ms) — RUM",
    f"A = data('rum.page_view.time.ns.p75', filter={RUMAPP}).mean(by=['customer.location']).publish(label='ns', enable=False)\n"
    "B = (A / 1000000).publish(label='pageload_ms')", TSL),
 "p95 latency by city (ms) — Madrid watch": ("p95 latency by city (ms) — Madrid watch",
    f"A = histogram('spans', filter={GW}).percentile(pct=95, by=['customer.location']).publish(label='ns', enable=False)\n"
    "B = (A / 1000000).publish(label='p95_ms')", TSL),
 "Decline + throttle rate by tier": ("Decline rate by customer tier",
    f"d = histogram('spans', filter={GW} and filter('payment.outcome','partial','error')).count(by=['customer.tier']).publish(label='d', enable=False)\n"
    f"t = histogram('spans', filter={GW} and filter('payment.outcome','*')).count(by=['customer.tier']).publish(label='t', enable=False)\n"
    "r = (d / t).fill(value=0).publish(label='decline_rate')", TSL),
 "Customer tier mix (exec)": ("Customer tier mix",
    f"A = histogram('spans', filter={GW}).count(by=['customer.tier']).publish(label='tier_mix')", None),
 "Cache hit ratio by namespace (exec)": ("Client errors by city — RUM",
    f"A = data('rum.client_error.count', filter={RUMAPP}, rollup='sum').sum(by=['customer.location']).publish(label='client_errors')", TSA),
}

dash = req(f"/dashboard/{DASH}")
for entry in dash.get("charts", []):
    c = req(f"/chart/{entry['chartId']}")
    name = c.get("name")
    if name not in REWRITES:
        continue
    new_name, program, opts = REWRITES[name]
    body = {"name": new_name, "programText": program,
            "options": opts if opts else c.get("options")}
    req(f"/chart/{c['id']}", body, "PUT")
    print(f"updated: {name} -> {new_name}")
print("done")
