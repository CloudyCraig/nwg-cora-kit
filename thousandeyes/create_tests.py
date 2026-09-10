#!/usr/bin/env python3
"""Recreate the NatWest /api/process HTTP-server tests in ThousandEyes from
the exported definitions, retargeted at $DEMO_BASE_URL.

Usage:
    source ../config/kit.env
    python3 create_tests.py [--dry-run]

GOTCHA (learned the hard way): the target URL must be https:// — an http://
URL gets the certbot 301 and TE scores every round as a failure.
"""
import json, os, sys, urllib.request

TOK = os.environ["TE_BEARER_TOKEN"]
AID = os.environ["TE_ACCOUNT_GROUP_ID"]
BASE_URL = os.environ["DEMO_BASE_URL"].rstrip("/")
assert BASE_URL.startswith("https://"), "DEMO_BASE_URL must be https:// (http gets a 301 and TE fails)"
H = {"Authorization": f"Bearer {TOK}", "Accept": "application/json", "Content-Type": "application/json"}
DRY = "--dry-run" in sys.argv

KEEP = [  # fields the v6 create endpoint accepts
    "testName", "interval", "url", "protocol", "networkMeasurements", "mtuMeasurements",
    "bandwidthMeasurements", "bgpMeasurements", "httpTargetTime", "httpTimeLimit",
    "httpVersion", "followRedirects", "verifyCertificate", "sslVersionId",
    "postBody", "requestMethod", "contentRegex", "desiredStatusCode", "agents", "alertsEnabled",
]

src = json.load(open(os.path.join(os.path.dirname(__file__), "http_server_tests.json")))
for t in src:
    body = {k: t[k] for k in KEEP if k in t and t[k] is not None}
    body["url"] = BASE_URL + "/api/process"
    body["agents"] = [{"agentId": a["agentId"]} for a in (t.get("agents") or [])]
    if DRY:
        print("DRY:", body["testName"], "->", body["url"], f"({len(body['agents'])} agents)")
        continue
    req = urllib.request.Request(f"https://api.thousandeyes.com/tests/http-server/new?aid={AID}",
                                 data=json.dumps(body).encode(), headers=H)
    try:
        r = json.load(urllib.request.urlopen(req, timeout=30))
        made = r.get("test", [r])[0] if isinstance(r.get("test"), list) else r
        print("created:", made.get("testId"), body["testName"])
    except urllib.error.HTTPError as e:
        print("FAILED:", body["testName"], e.code, e.read().decode()[:150])
print("\nRemember: enable the 'Splunk Observability' stream integration on these tests")
print("(TE console -> Integrations) so results land in index=thousandeyes via the O11y pipeline.")
