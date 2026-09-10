"""cora-loadgen: reactive Cora traffic.

Polls the chaos-controller's read-only scenario list. While a trigger
scenario (the Madrid pair by default) is armed, simulates customers
asking Cora why their payments fail - elevated rate with a hallucination
mix - so AI Monitoring shows a usage/cost spike with quality issues
alongside the AML outage. Baseline: a light trickle of normal asks.
Read-only against chaos state; only ever POSTs to cora-agent /ask.
"""
import json
import os
import random
import time
import urllib.request

CHAOS_URL = os.environ.get(
    "CHAOS_SCENARIOS_URL",
    "http://chaos-controller.natwest.svc.cluster.local:8080/chaos/api/scenarios")
CORA_URL = os.environ.get(
    "CORA_ASK_URL", "http://cora-agent.natwest.svc.cluster.local:8080/ask")
TRIGGERS = {s.strip() for s in os.environ.get(
    "TRIGGER_SCENARIOS",
    "madrid-payment-degradation,madrid-network-degradation").split(",") if s.strip()}
BURST_INTERVAL_S = float(os.environ.get("BURST_INTERVAL_S", "7"))
BASE_INTERVAL_S = float(os.environ.get("BASE_INTERVAL_S", "150"))
HALLU_PROB = float(os.environ.get("HALLU_PROB", "0.35"))
POLL_S = float(os.environ.get("POLL_S", "15"))

BURST_QUESTIONS = [
    "Why did my payment to Madrid fail?",
    "My transfer to Spain keeps failing, why?",
    "Why was my SEPA payment declined?",
    "I cannot send money to my sister in Madrid, what is wrong?",
    "Why is my payment stuck in pending?",
    "My payment failed twice, will I be charged twice?",
    "Why did my euro transfer bounce?",
    "Is there a problem with payments right now?",
    "Why cant I pay my Iberdrola bill?",
    "My payment to Spain says failed, what should I do?",
]
BASE_QUESTIONS = [
    "Why did my payment fail?",
    "How long does a SEPA payment take?",
    "Why was my card declined?",
    "What is my daily payment limit?",
]


def poll_enabled() -> bool:
    """Presenter on/off switch, served by cora-agent /traffic-config."""
    url = CORA_URL.rsplit("/", 1)[0] + "/traffic-config"
    try:
        with urllib.request.urlopen(url, timeout=8) as resp:
            return bool(json.loads(resp.read()).get("enabled"))
    except Exception as exc:  # noqa: BLE001
        print(f"loadgen enabled_poll_error {exc!r}", flush=True)
        return False


def poll_armed() -> bool:
    try:
        req = urllib.request.Request(CHAOS_URL)
        tok_path = os.environ.get("CHAOS_TOKEN_PATH", "/var/run/chaos/CHAOS_PRESENTER_TOKEN")
        if os.path.exists(tok_path):
            with open(tok_path) as fh:
                req.add_header("X-Chaos-Token", fh.read().strip())
        with urllib.request.urlopen(req, timeout=8) as resp:
            data = json.loads(resp.read())
    except Exception as exc:  # noqa: BLE001
        print(f"loadgen poll_error {exc!r}", flush=True)
        return False
    items = data.get("scenarios") or data.get("items") or []
    armed_ids = {
        it.get("id") for it in items
        if it.get("status", {}).get("state") == "armed"
    }
    return bool(armed_ids & TRIGGERS)


def ask(question: str, mode: str) -> None:
    payload = json.dumps({"question": question, "mode": mode}).encode()
    req = urllib.request.Request(
        CORA_URL, data=payload, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=55) as resp:
            resp.read()
        print(f"loadgen ask mode={mode} ok", flush=True)
    except Exception as exc:  # noqa: BLE001
        print(f"loadgen ask_error mode={mode} {exc!r}", flush=True)


def main() -> None:
    print(f"loadgen start triggers={sorted(TRIGGERS)} "
          f"burst={BURST_INTERVAL_S}s base={BASE_INTERVAL_S}s "
          f"hallu={HALLU_PROB}", flush=True)
    armed = False
    enabled = False
    last_poll = 0.0
    next_ask = time.time() + 10
    while True:
        now = time.time()
        if now - last_poll >= POLL_S:
            was = armed
            was_enabled = enabled
            enabled = poll_enabled()
            armed = poll_armed() if enabled else False
            last_poll = now
            if enabled != was_enabled:
                print(f"loadgen traffic_enabled={enabled}", flush=True)
            if armed != was:
                print(f"loadgen trigger_state armed={armed}", flush=True)
                if armed:
                    next_ask = now + 2  # react quickly when the scenario arms
        if enabled and now >= next_ask:
            if armed:
                mode = "hallucinate" if random.random() < HALLU_PROB else "normal"
                q = random.choice(BURST_QUESTIONS)
                interval = BURST_INTERVAL_S
            else:
                mode = "normal"
                q = random.choice(BASE_QUESTIONS)
                interval = BASE_INTERVAL_S
            ask(q, mode)
            next_ask = time.time() + interval * (0.7 + 0.6 * random.random())
        time.sleep(1)


if __name__ == "__main__":
    main()
