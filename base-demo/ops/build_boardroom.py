#!/usr/bin/env python3
"""'NatWest Payments — Boardroom': deluxe clone of the exec dashboard.
Thresholded KPI tiles (org palette: 16=red..20=green), tamed precision,
and a full-width SVG payment-flow banner (markdown data-URI experiment)."""
import json, base64, urllib.request, sys

TOKEN = open("/tmp/sfx_token_run").read().strip()
API = "https://api.eu0.signalfx.com/v2"
SRC_DASH = "HNLjM2GAAAA"
GROUP = "HLKcs21AIAY"

def req(path, body=None, method="GET"):
    r = urllib.request.Request(API + path, method=method,
        headers={"X-SF-TOKEN": TOKEN, "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body else None)
    try:
        with urllib.request.urlopen(r) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        print("API ERROR", e.code, path, ":", e.read().decode()[:300]); sys.exit(1)

def scale(*bands):  # bands: (gt, lte, idx)
    return [{"gt": g, "gte": None, "lt": None, "lte": l, "paletteIndex": i} for g, l, i in bands]

# KPI enhancements by chart name: (colorScale2 or None, maximumPrecision)
KPI = {
 "Payment journeys per minute": (None, 0),
 "Madrid p95 latency (ms)": (scale((2000, None, 16), (800, 2000, 17), (None, 800, 20)), 0),
 "Decline rate %": (scale((8, None, 16), (2, 8, 17), (None, 2, 20)), 1),
 "Customer conversion %": (scale((90, None, 20), (75, 90, 17), (None, 75, 16)), 1),
 "p99 payment latency (ms)": (scale((3000, None, 16), (1500, 3000, 17), (None, 1500, 20)), 0),
}

# --- SVG flow banner -----------------------------------------------------
NODES = [("CUSTOMER", "web & mobile"), ("EXPERIENCE", "natwest SPA"),
         ("GATEWAY", "api-gateway"), ("SCREENING", "sanctions / AML"),
         ("RAILS", "FPS · SEPA · CHAPS"), ("LEDGER", "settlement")]
parts = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1440 150" font-family="Helvetica,Arial,sans-serif">']
parts.append('<text x="24" y="34" fill="#c3cbd9" font-size="19" font-weight="bold" letter-spacing="3">NATWEST PAYMENTS — LIVE PLATFORM FLOW</text>')
x, w, gap, y = 24, 200, 36, 58
for i, (title, sub) in enumerate(NODES):
    parts.append(f'<rect x="{x}" y="{y}" rx="12" width="{w}" height="64" fill="#171d2b" stroke="#7c6bff" stroke-width="1.5"/>')
    parts.append(f'<text x="{x+w/2}" y="{y+28}" fill="#ffffff" font-size="16" font-weight="bold" text-anchor="middle" letter-spacing="1.5">{title}</text>')
    parts.append(f'<text x="{x+w/2}" y="{y+48}" fill="#8b94a8" font-size="12" text-anchor="middle">{sub}</text>')
    if i < len(NODES) - 1:
        ax = x + w + 4
        parts.append(f'<path d="M {ax} {y+32} h {gap-14} m -8 -7 l 8 7 l -8 7" stroke="#ed0080" stroke-width="2.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/>')
    x += w + gap
parts.append('<text x="1416" y="140" fill="#5b6474" font-size="11" text-anchor="end">healthy → green KPIs above · Madrid degradation → amber/red + declines swell</text>')
parts.append('</svg>')
svg_b64 = base64.b64encode("".join(parts).encode()).decode()
BANNER_MD = f"![flow](data:image/svg+xml;base64,{svg_b64})"

src = req(f"/dashboard/{SRC_DASH}")
new_charts = []
for entry in src["charts"]:
    c = req(f"/chart/{entry['chartId']}")
    name, opts = c["name"], dict(c.get("options", {}))
    if name.startswith("hdr"):
        continue  # replaced by the banner
    if name in KPI:
        cs, prec = KPI[name]
        opts["colorBy"] = "Scale" if cs else opts.get("colorBy", "Dimension")
        if cs: opts["colorScale2"] = cs
        opts["maximumPrecision"] = prec
    nc = req("/chart", {"name": name + " ", "programText": c["programText"], "options": opts}, "POST")
    row = entry["row"]
    new_charts.append({"chartId": nc["id"], "row": row, "column": entry["column"],
                       "width": entry["width"], "height": entry["height"]})
    print("cloned:", name)

banner = req("/chart", {"name": "flow-banner", "programText": "",
                        "options": {"type": "Text", "markdown": BANNER_MD}}, "POST")
new_charts.append({"chartId": banner["id"], "row": 1, "column": 0, "width": 12, "height": 1})
print("banner chart:", banner["id"])

dash = req("/dashboard", {
    "name": "NatWest Payments — Boardroom",
    "groupId": GROUP,
    "description": "Deluxe exec view: thresholded KPIs (green/amber/red), payment-flow banner. Present via Dashboard actions > View fullscreen.",
    "charts": new_charts}, "POST")
print("DASHBOARD:", dash["id"])
print(f"URL: https://app.eu0.signalfx.com/#/dashboard/{dash['id']}")
