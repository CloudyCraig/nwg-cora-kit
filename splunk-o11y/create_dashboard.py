#!/usr/bin/env python3
"""Recreate the 'Cora AI cost & usage' dashboard (group + 7 charts) in any
Observability Cloud org, from the exported JSON in this directory.

Usage:
    source ../config/kit.env
    python3 create_dashboard.py

Renames every chart/dashboard occurrence of the original agent name to
$CORA_AGENT_NAME. Requires SPLUNK_API_TOKEN + SPLUNK_REALM in the env.
"""
import json, os, urllib.request

REALM = os.environ["SPLUNK_REALM"]
TOKEN = os.environ["SPLUNK_API_TOKEN"]
AGENT = os.environ.get("CORA_AGENT_NAME", "Cora")
BASE = f"https://api.{REALM}.signalfx.com"
H = {"X-SF-Token": TOKEN, "Content-Type": "application/json"}

def post(path, body):
    req = urllib.request.Request(f"{BASE}{path}", data=json.dumps(body).encode(), headers=H)
    return json.load(urllib.request.urlopen(req, timeout=30))

def scrub(obj, drop=("id", "creator", "lastUpdatedBy", "created", "lastUpdated", "lockedBy")):
    if isinstance(obj, dict):
        return {k: scrub(v, drop) for k, v in obj.items() if k not in drop}
    if isinstance(obj, list):
        return [scrub(v, drop) for v in obj]
    if isinstance(obj, str):
        return obj.replace("Cora", AGENT)
    return obj

charts_src = json.load(open(os.path.join(os.path.dirname(__file__), "charts_cora_dashboard.json")))
dash_src = json.load(open(os.path.join(os.path.dirname(__file__), "dashboard_cora_ai_cost_usage.json")))

# 1) group
grp = post("/v2/dashboardgroup", {"name": f"{AGENT} AI Monitoring", "description": "nwg-cora-kit", "dashboardConfigs": []})
print("group:", grp["id"])

# 2) charts (old id -> new id)
id_map = {}
for old_id, chart in charts_src.items():
    body = scrub(chart)
    # SingleValue charts: strip options the API rejects (unit/numberPrecision/showSparkLine)
    if body.get("options", {}).get("type") == "SingleValue":
        body["options"] = {"type": "SingleValue"}
    new = post("/v2/chart", body)
    id_map[old_id] = new["id"]
    print("chart:", new["id"], "<-", body.get("name", "?")[:40])

# 3) dashboard with remapped chart ids
dash = scrub(dash_src)
dash["groupId"] = grp["id"]
for w in dash.get("charts", []):
    w["chartId"] = id_map[[k for k in id_map if k == w["chartId"]] and w["chartId"]] if w["chartId"] in id_map else w["chartId"]
    w["chartId"] = id_map.get(w["chartId"], w["chartId"])
dash.pop("authorizedWriters", None)
new_dash = post("/v2/dashboard", dash)
print("dashboard:", new_dash["id"], f"-> https://app.{REALM}.signalfx.com/#/dashboard/{new_dash['id']}")
print("\nNOTE: charts read gen_ai.agent.duration / gen_ai.cost2.* — they populate once the agent emits.")
