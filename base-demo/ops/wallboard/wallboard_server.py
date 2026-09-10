#!/usr/bin/env python3
"""NatWest Payments live wallboard — stdlib-only data aggregator + static server.

Polls Splunk Observability Cloud (SignalFlow) and ITSI (localhost REST) in a
background thread; serves index.html and /data.json. Fronted by nginx at
/wallboard/. No external dependencies."""
import base64
import json
import os
import ssl
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
SFX_TOKEN = open(os.path.join(HERE, "sfx_token")).read().strip()
SPLUNK_B64 = base64.b64encode(b"admin:smartway").decode()
SSL_CTX = ssl.create_default_context()
SSL_CTX.check_hostname = False
SSL_CTX.verify_mode = ssl.CERT_NONE

GW = "filter('sf_service','api-gateway') and filter('sf_environment','demo')"

# Wallboard pipeline element -> ITSI service title (exact, from the service tree)
ITSI_MAP = {
    "experience": "Digital Customer Experience",
    "gateway": "Payments Service API gateway",
    "initiation": "payment-initiation-service",
    "validation": "payment-validation-service",
    "screening": "sanctions-aml-service",
    "rails": "Payment Networks",
    "ledger": "ledger-service",
    "settlement": "settlement-service",
    "by_location": "Payments by Location",
}

STATE = {"ts": 0, "kpis": {}, "cities": {}, "health": {}, "outcome": {}}
_LOCK = threading.Lock()


def sf_execute(program, window_ms=300_000, res_ms=60_000):
    """Run a SignalFlow program, return list of (properties, latest_value)."""
    now = int(time.time() * 1000)
    url = (f"https://stream.eu0.signalfx.com/v2/signalflow/execute"
           f"?start={now - window_ms}&stop={now}&resolution={res_ms}&immediate=true")
    req = urllib.request.Request(url, data=program.encode(),
        headers={"X-SF-TOKEN": SFX_TOKEN, "Content-Type": "text/plain"})
    raw = urllib.request.urlopen(req, timeout=25).read().decode(errors="ignore")
    tsmap, latest = {}, {}
    for event in raw.split("\n\n"):
        etype, payload_lines = None, []
        for line in event.split("\n"):
            if line.startswith("event:"):
                etype = line[6:].strip()
            elif line.startswith("data:"):
                payload_lines.append(line[5:])
        payload = "\n".join(payload_lines)
        if not payload.strip():
            continue
        try:
            obj = json.loads(payload)
        except ValueError:
            continue
        if etype == "metadata":
            tsmap[obj.get("tsId")] = obj.get("properties", {})
        elif etype == "data":
            for d in obj.get("data", []):
                if d.get("value") is not None:
                    latest[d.get("tsId")] = d["value"]
    return [(tsmap.get(k, {}), v) for k, v in latest.items()]


def splunk_oneshot(spl):
    req = urllib.request.Request(
        "https://127.0.0.1:8089/services/search/jobs",
        data=urllib.parse.urlencode({"search": spl, "exec_mode": "oneshot",
                                     "output_mode": "json"}).encode(),
        headers={"Authorization": "Basic " + SPLUNK_B64})
    return json.loads(urllib.request.urlopen(req, timeout=30, context=SSL_CTX).read())


_SERVICE_IDS = {}  # itsi service title -> _key


def load_itsi_services():
    req = urllib.request.Request(
        "https://127.0.0.1:8089/servicesNS/nobody/SA-ITOA/itoa_interface/service"
        "?fields=title,_key",
        headers={"Authorization": "Basic " + SPLUNK_B64})
    for svc in json.loads(urllib.request.urlopen(req, timeout=30, context=SSL_CTX).read()):
        _SERVICE_IDS[svc.get("title", "")] = svc.get("_key", "")


def poll_signalflow():
    out = {}
    rows = sf_execute(
        f"A = histogram('spans', filter={GW} and "
        "filter('payment.outcome','success','partial','error'))"
        ".count(by=['payment.outcome']).publish()")
    outcome = {p.get("payment.outcome", "?"): v for p, v in rows}
    total = sum(outcome.values()) or 1
    out["outcome"] = outcome
    out["conversion_pct"] = round(outcome.get("success", 0) / total * 100, 1)
    out["decline_pct"] = round(
        (outcome.get("partial", 0) + outcome.get("error", 0)) / total * 100, 1)

    rows = sf_execute(
        f"A = histogram('spans', filter={GW} and filter('customer.location','*'))"
        ".percentile(pct=95, by=['customer.location']).publish()")
    out["cities"] = {p.get("customer.location", "?"): round(v / 1e6)
                     for p, v in rows if p.get("customer.location")}

    rows = sf_execute(
        f"A = histogram('spans', filter={GW} and filter('payment.scheme','*'))"
        ".count(by=['payment.scheme']).publish(label='j')\n"
        f"B = histogram('spans', filter={GW} and filter('payment.scheme','*'))"
        ".percentile(pct=99).publish(label='p')")
    journeys, p99 = 0, 0
    for p, v in rows:
        if p.get("payment.scheme"):
            journeys += v
        elif v > 1000:  # the percentile stream (ns scale)
            p99 = v
    out["journeys_min"] = round(journeys)
    out["p99_ms"] = round(p99 / 1e6)
    out["madrid_p95_ms"] = out["cities"].get("madrid", 0)
    return out


def poll_itsi_health():
    res = splunk_oneshot(
        "search index=itsi_summary kpi=ServiceHealthScore earliest=-15m "
        "| stats latest(alert_value) as health by serviceid")
    by_id = {r["serviceid"]: float(r["health"]) for r in res.get("results", [])
             if r.get("health") not in (None, "", "N/A")}
    return {el: by_id.get(_SERVICE_IDS.get(title, ""), None)
            for el, title in ITSI_MAP.items()}


def poller():
    while True:
        snap = {}
        try:
            snap.update(poll_signalflow())
        except Exception as e:  # noqa: BLE001
            snap["sfx_error"] = str(e)[:200]
        try:
            if not _SERVICE_IDS:
                load_itsi_services()
            snap["health"] = poll_itsi_health()
        except Exception as e:  # noqa: BLE001
            snap["itsi_error"] = str(e)[:200]
        snap["ts"] = int(time.time())
        with _LOCK:
            STATE.clear()
            STATE.update(snap)
        time.sleep(15)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        path = self.path.split("?")[0]
        if path.rstrip("/") in ("", "/index.html") or path == "/":
            body = open(os.path.join(HERE, "index.html"), "rb").read()
            self._send(200, "text/html", body)
        elif path == "/data.json":
            with _LOCK:
                body = json.dumps(STATE).encode()
            self._send(200, "application/json", body)
        else:
            self._send(404, "text/plain", b"not found")

    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):  # quiet
        pass


if __name__ == "__main__":
    threading.Thread(target=poller, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", 8090), Handler).serve_forever()
