import os, json, logging, time
from flask import Flask, request, jsonify
import anthropic

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("cora-agent")

MODEL = os.environ.get("CORA_MODEL", "claude-opus-5")
MAX_TOKENS = int(os.environ.get("CORA_MAX_TOKENS", "512"))
# USD per 1M tokens (claude-haiku-4-5 list price; overridable per model)
PRICE_IN_PER_MTOK = float(os.environ.get("CORA_PRICE_IN", "1.0"))
PRICE_OUT_PER_MTOK = float(os.environ.get("CORA_PRICE_OUT", "5.0"))

app = Flask(__name__)
client = anthropic.Anthropic()  # reads ANTHROPIC_API_KEY from env

# --- Splunk HEC emit (for the ITSI "AI agents" service KPIs) ---------------
# Reuses the same HEC endpoint/token the chaos-controller audits through
# (secret chaos-controller-token). Fire-and-forget on a daemon thread so a
# slow/unreachable HEC never adds latency to /ask. sourcetype nwpay:cora.
import ssl as _ssl
import threading as _threading

_HEC_URL = os.environ.get("SPLUNK_HEC_ENDPOINT", "").strip().rstrip("/")
# The secret stores the bare host:port; HEC's event endpoint lives under
# /services/collector/event (posting to the bare base 404s).
if _HEC_URL and "/services/collector" not in _HEC_URL:
    _HEC_URL += "/services/collector/event"
_HEC_TOK = os.environ.get("SPLUNK_HEC_TOKEN", "").strip()
_HEC_IDX = os.environ.get("SPLUNK_HEC_INDEX", "nwpay_audit").strip() or "nwpay_audit"
_HEC_CTX = _ssl.create_default_context()
_HEC_CTX.check_hostname = False
_HEC_CTX.verify_mode = _ssl.CERT_NONE  # demo Splunk uses a self-signed cert

def _hec_emit(event: dict) -> None:
    if not (_HEC_URL and _HEC_TOK):
        return
    def _send() -> None:
        try:
            import urllib.request as _ur
            payload = json.dumps({
                "index": _HEC_IDX,
                "sourcetype": "nwpay:cora",
                "source": "cora-agent",
                "event": event,
            }).encode()
            req = _ur.Request(_HEC_URL, data=payload, headers={
                "Authorization": "Splunk " + _HEC_TOK,
                "Content-Type": "application/json",
            })
            _ur.urlopen(req, timeout=4, context=_HEC_CTX).read()
        except Exception as exc:  # noqa: BLE001
            log.debug("hec emit failed: %s", exc)
    _threading.Thread(target=_send, daemon=True).start()

# Agent-level span: Splunk AI Agent Monitoring's "AI Agents" + "AI Overview"
# views aggregate by AgentInvocation (gen_ai.operation.name=invoke_agent),
# NOT by raw LLM chat spans. Wrapping each call in an invoke_agent span (OTel
# GenAI / Cisco AGNTCY agent semconv) makes Cora appear as an agent there.
from opentelemetry import trace as _trace
# Scope name matters: Splunk's AI pipeline classifies GenAI spans partly by
# instrumentation scope (the anthropic 'chat' spans come from a recognized
# scope). Use the Splunk/OTel GenAI utility's scope so agent spans classify.
_tracer = _trace.get_tracer("opentelemetry.util.genai")
AGENT_NAME = os.environ.get("CORA_AGENT_NAME", "Cora")
AGENT_ID = "cora-natwest-assistant"

# Splunk's AI Overview/Agents aggregate CHAT spans BY gen_ai.agent.name (the
# fork's emitter stamps the agent onto child LLM spans). The anthropic
# auto-instrumentation doesn't, so stamp it via a span processor.
try:
    from opentelemetry.sdk.trace import SpanProcessor as _SP

    class _AgentStamp(_SP):
        def on_start(self, span, parent_context=None):
            try:
                n = getattr(span, "name", "") or ""
                if n.startswith(("anthropic.", "chat", "invoke_agent", "create_agent", "workflow ")):
                    span.set_attribute("gen_ai.evaluation.sampled", True)
                    if not n.startswith("workflow "):
                        span.set_attribute("gen_ai.agent.name", AGENT_NAME)
                        span.set_attribute("gen_ai.agent.id", AGENT_ID)
            except Exception:  # noqa: BLE001
                pass
        def on_end(self, span): pass
        def shutdown(self): pass
        def force_flush(self, timeout_millis=30000): return True

    _tp0 = _trace.get_tracer_provider()
    if hasattr(_tp0, "add_span_processor"):
        _tp0.add_span_processor(_AgentStamp())
        log.info("agent-name stamping span processor active")
except Exception as _e:  # noqa: BLE001
    log.warning("agent stamp setup failed: %s", _e)

# Secondary trace export REMOVED (2026-09-03): cora-otelcol now feeds the
# main NWG demo org (HB_UFNBCsAw), which already receives Cora's spans via
# the primary path (env OTLP -> node collector) - exporting them again
# through cora-otelcol would double-ingest identical spans. The collector's
# traces pipeline is gone too; only native gen_ai metrics ship through it.
_second = os.environ.get("CORA_SECONDARY_OTLP_ENDPOINT")

# Secondary METRICS export (ADDITIVE) -> cora-otelcol -> AI-enabled org.
# Splunk AI Overview + AI Agents are driven by gen_ai.client.* METRICS, not
# spans; the auto-instrumentation only sends those to the primary (node
# collector -> original org). Re-emit the same gen_ai metrics to a dedicated
# MeterProvider so they ALSO reach the new org. Primary path is untouched.
_tok_hist = None
_dur_hist = None
_agent_dur_hist = None
_cost_in_hist = None
_cost_out_hist = None
_cost2_in_hist = None
_cost2_out_hist = None
if _second:
    try:
        from opentelemetry.sdk.metrics import MeterProvider as _MP
        from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader as _PR
        from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter as _ME
        from opentelemetry.sdk.resources import Resource as _R
        # sf_environment is what Splunk's APM/AI Environment filter keys on;
        # the signalfx metric exporter does NOT derive it from
        # deployment.environment (unlike the trace pipeline), so set it here.
        # NOTE (2026-09-03): tested service.name=cora-assistant here to see if
        # a fresh dimension set escapes the eu2 ingest block on the standard
        # gen_ai.client.* names. It does not: agent.duration minted a new MTS
        # instantly, token.usage/operation.duration minted none. Block is
        # name-scoped per org; only Splunk can lift it. Reverted.
        _res2 = _R.create({"service.name": "cora-agent", "deployment.environment": "demo", "sf_environment": "demo"})
        _rdr = _PR(_ME(endpoint=_second, insecure=True), export_interval_millis=10000)
        _mp2 = _MP(metric_readers=[_rdr], resource=_res2)
        _meter2 = _mp2.get_meter("cora-agent-genai")
        _tok_hist = _meter2.create_histogram("gen_ai.client.token.usage", unit="{token}")
        _dur_hist = _meter2.create_histogram("gen_ai.client.operation.duration", unit="s")
        # Splunk counts monitored agents from gen_ai.agent.name on metrics, and
        # the AI Agents view reads gen_ai.agent.duration (per the splunk fork's
        # metric emitter). Emit that too so "Cora" registers as an agent.
        _agent_dur_hist = _meter2.create_histogram("gen_ai.agent.duration", unit="s")
        # Cost tiles in AI Monitoring read gen_ai.cost.input/output histograms
        # (shape observed in a working reference org). Priced per official
        # Anthropic rates for the model in use (USD per token).
        _cost_in_hist = _meter2.create_histogram("gen_ai.cost.input", unit="{usd}")
        _cost_out_hist = _meter2.create_histogram("gen_ai.cost.output", unit="{usd}")
        # namespace-drop experiment: identical histograms under a different name
        _cost2_in_hist = _meter2.create_histogram("gen_ai.cost2.input", unit="{usd}")
        _cost2_out_hist = _meter2.create_histogram("gen_ai.cost2.output", unit="{usd}")
        log.info("secondary gen_ai metrics export -> %s", _second)
    except Exception as _e:  # noqa: BLE001
        log.warning("secondary metrics setup failed: %s", _e)

SYSTEM_GROUNDED = (
    "You are Cora, NatWest's friendly AI banking assistant in the mobile/online "
    "banking app. Answer the customer's question concisely and accurately in 2-4 "
    "sentences. If a payment failed, explain the common legitimate reasons "
    "(insufficient funds, a daily/payee limit, wrong card or payee details, a fraud "
    "or sanctions screening check, or a temporary technical issue) and offer one next "
    "step. Never invent NatWest policies, fees, or specifics about the customer's account."
)

# Phase 3 demo mode: deterministic FIXTURE wrong-answers (no LLM involvement
# in the faulty content) so Splunk's hallucination evaluator has something to
# flag. Fixture data for a fictional demo — repeatable on every run.
CANNED_HALLUCINATIONS = [
    "Your payment was held by our Rule 7b overnight settlement freeze, which "
    "pauses all transfers made after 4:12pm. It will be released once the "
    "£4.20 Payment Assurance Levy is collected. No action is needed.",
    "This failed because your payee hasn't completed Tier-3 vetting with our "
    "Payee Verification Desk in Sheffield. Ask them to text VERIFY to 60060 "
    "and the block lifts within 90 minutes.",
    "Faster Payments are limited to 3 transfers per calendar day under the "
    "2019 Consumer Payments Charter; you've used all 3 today, so this one "
    "was declined. Your allowance resets at 22:00.",
    "Our records show your account is enrolled in Eco-Save mode, which "
    "blocks card payments on Fridays to reduce processing emissions. You "
    "can opt out for a £1.50 monthly fee in the app.",
    "The transfer bounced because the receiving bank hasn't upgraded to the "
    "ISO-9 FastRail messaging standard. We retry every 6 hours for up to 8 "
    "days, and a 35p retry fee applies to each attempt.",
    "Your payment exceeded the £48.12 micro-limit that applies to all new "
    "payees for their first 30 days. Split it into two smaller amounts and "
    "both will go through instantly.",
]

@app.get("/health")
@app.get("/readyz")
def health():
    return "ok\n", 200

# Presenter control for the cora-loadgen background traffic (real Anthropic
# calls cost money, so the stream is switchable from the Ops page). State is
# in-memory; the env default means a pod restart returns to a known setting.
TRAFFIC_STATE = {
    "enabled": os.environ.get("CORA_TRAFFIC_DEFAULT", "off").lower() == "on"
}

@app.get("/traffic-config")
def traffic_config_get():
    return jsonify({"enabled": TRAFFIC_STATE["enabled"]})

@app.post("/traffic-config")
def traffic_config_set():
    body = request.get_json(silent=True) or {}
    enabled = bool(body.get("enabled"))
    TRAFFIC_STATE["enabled"] = enabled
    log.info("cora_traffic_config enabled=%s", enabled)
    return jsonify({"enabled": enabled})

@app.post("/ask")
def ask():
    body = request.get_json(silent=True) or {}
    question = (body.get("question") or "").strip()
    if not question:
        return jsonify({"error": "missing 'question'"}), 400
    mode = (body.get("mode") or "normal").lower()
    # Both modes present the GROUNDED instructions in telemetry — in
    # hallucinate mode the fixture answer visibly violates them, which is
    # what the hallucination evaluator keys on.
    system_prompt = SYSTEM_GROUNDED
    try:
        # OTel GenAI agent-span semconv: agent spans are CLIENT kind, required
        # provider attr is gen_ai.provider.name. Splunk registers an agent from
        # the create_agent span (where gen_ai.agent.name first appears); the
        # nested invoke_agent span is the invocation, and the anthropic 'chat'
        # LLM span nests under that. This lights up AI Agents + AI Overview.
        _agent_attrs = {
            "gen_ai.provider.name": "anthropic",
            "gen_ai.system": "anthropic",
            "gen_ai.agent.name": AGENT_NAME,
            "gen_ai.agent.id": "cora-natwest-assistant",
            "server.address": "api.anthropic.com",
            "gen_ai.request.model": MODEL,
        }
        _CLIENT = _trace.SpanKind.CLIENT
        # Structure replicated from Splunk's own splunk-otel-util-genai
        # emitter (verified via a local probe app): a root "workflow" span
        # with gen_ai.conversation_root=True, an INTERNAL invoke_agent span
        # (with gen_ai.framework + evaluation.sampled), and the chat span
        # nested inside. No create_agent span.
        _sysinstr = json.dumps([{"type": "text", "content": system_prompt}])
        _inmsgs = json.dumps([{"role": "user", "parts": [{"type": "text", "content": question}]}])
        with _tracer.start_as_current_span("workflow cora_assistant") as _wf:
            _wf.set_attribute("gen_ai.operation.name", "invoke_workflow")
            _wf.set_attribute("gen_ai.workflow.name", "cora_assistant")
            _wf.set_attribute("gen_ai.conversation_root", True)
            _wf.set_attribute("gen_ai.evaluation.sampled", True)
            _wf.set_attribute("gen_ai.input.messages", _inmsgs)
            with _tracer.start_as_current_span("invoke_agent " + AGENT_NAME) as _agent_span:
                _agent_span.set_attribute("gen_ai.operation.name", "invoke_agent")
                _agent_span.set_attribute("gen_ai.framework", "custom")
                _agent_span.set_attribute("gen_ai.evaluation.sampled", True)
                _agent_span.set_attribute("gen_ai.system_instructions", _sysinstr)
                _agent_span.set_attribute("gen_ai.input.messages", _inmsgs)
                for _k, _v in _agent_attrs.items():
                    _agent_span.set_attribute(_k, _v)
                if mode == "hallucinate":
                    # Fixture wrong-answer + synthetic chat span (no real LLM
                    # call for the faulty content — deterministic demo data).
                    answer = CANNED_HALLUCINATIONS[
                        sum(ord(c) for c in question) % len(CANNED_HALLUCINATIONS)]
                    _in_tok = 120 + len(question) // 4
                    _out_tok = max(20, len(answer) // 4)
                    _t0 = time.time()
                    with _tracer.start_as_current_span("anthropic.chat", kind=_CLIENT) as _cs:
                        _cs.set_attribute("gen_ai.operation.name", "chat")
                        _cs.set_attribute("gen_ai.provider.name", "anthropic")
                        _cs.set_attribute("gen_ai.system", "anthropic")
                        _cs.set_attribute("gen_ai.request.model", MODEL)
                        _cs.set_attribute("gen_ai.response.model", MODEL)
                        _cs.set_attribute("gen_ai.request.max_tokens", MAX_TOKENS)
                        _cs.set_attribute("gen_ai.system_instructions", _sysinstr)
                        _cs.set_attribute("gen_ai.input.messages", _inmsgs)
                        time.sleep(0.9 + (len(question) % 5) / 10.0)  # realistic latency
                        _cs.set_attribute("gen_ai.output.messages", json.dumps([
                            {"role": "assistant",
                             "parts": [{"type": "text", "content": answer}],
                             "finish_reason": "stop"}
                        ]))
                        _cs.set_attribute("gen_ai.usage.input_tokens", _in_tok)
                        _cs.set_attribute("gen_ai.usage.output_tokens", _out_tok)
                        _cs.set_attribute("gen_ai.response.finish_reasons", ["stop"])
                    _elapsed = time.time() - _t0
                    _resp_model, _usage_in, _usage_out, _finish = MODEL, _in_tok, _out_tok, "stop"
                else:
                    _t0 = time.time()
                    resp = client.messages.create(
                        model=MODEL,
                        max_tokens=MAX_TOKENS,
                        system=system_prompt,
                        messages=[{"role": "user", "content": question}],
                    )
                    _elapsed = time.time() - _t0
                    answer = "".join(b.text for b in resp.content if b.type == "text").strip()
                    _resp_model = resp.model
                    _usage_in = resp.usage.input_tokens
                    _usage_out = resp.usage.output_tokens
                    _finish = getattr(resp, "stop_reason", None) or "stop"
                _agent_span.set_attribute("gen_ai.output.messages", json.dumps([
                    {"role": "assistant",
                     "parts": [{"type": "text", "content": answer}],
                     "finish_reason": _finish}
                ]))
                _agent_span.set_attribute("gen_ai.usage.input_tokens", _usage_in)
                _agent_span.set_attribute("gen_ai.usage.output_tokens", _usage_out)
                _agent_span.set_attribute("gen_ai.response.model", _resp_model)
                _agent_span.set_attribute("gen_ai.response.finish_reasons", [_finish])
                # fan the gen_ai metrics out to the AI-enabled org (matches the
                # instrumentation's own gen_ai.client.* metric shape)
                if _tok_hist is not None:
                    # gen_ai.agent.name is the dimension Splunk counts agents by
                    _ma = {"gen_ai.provider.name": "anthropic", "gen_ai.response.model": _resp_model,
                           "gen_ai.request.model": MODEL,
                           "gen_ai.operation.name": "chat", "gen_ai.agent.name": AGENT_NAME}
                    _tok_hist.record(_usage_in, {**_ma, "gen_ai.token.type": "input"})
                    _tok_hist.record(_usage_out, {**_ma, "gen_ai.token.type": "output"})
                    _dur_hist.record(_elapsed, _ma)
                    _agent_dur_hist.record(_elapsed, {
                        "gen_ai.operation.name": "invoke_agent",
                        "gen_ai.agent.name": AGENT_NAME,
                        "gen_ai.agent.type": "assistant",
                        "gen_ai.provider.name": "anthropic",
                    })
                    # Cost tiles read gen_ai.cost.* histograms (USD)
                    _cattrs = {"gen_ai.provider.name": "anthropic",
                               "gen_ai.request.model": MODEL,
                               "gen_ai.agent.name": AGENT_NAME}
                    if _cost_in_hist is not None:
                        _cost_in_hist.record(_usage_in / 1e6 * PRICE_IN_PER_MTOK,
                                             {**_cattrs, "gen_ai.token.type": "input"})
                        _cost_out_hist.record(_usage_out / 1e6 * PRICE_OUT_PER_MTOK,
                                              {**_cattrs, "gen_ai.token.type": "output"})
                        _cost2_in_hist.record(_usage_in / 1e6 * PRICE_IN_PER_MTOK,
                                              {**_cattrs, "gen_ai.token.type": "input"})
                        _cost2_out_hist.record(_usage_out / 1e6 * PRICE_OUT_PER_MTOK,
                                               {**_cattrs, "gen_ai.token.type": "output"})
            _wf.set_attribute("gen_ai.output.messages", json.dumps([
                {"role": "assistant",
                 "parts": [{"type": "text", "content": answer}],
                 "finish_reason": _finish}
            ]))
        _ask_event = {
            "action": "cora_ask",
            "agent": AGENT_NAME,
            "mode": mode,
            "hallucinated": mode == "hallucinate",
            "model": _resp_model,
            "tokens_in": _usage_in,
            "tokens_out": _usage_out,
            "cost_usd": round(_usage_in / 1e6 * PRICE_IN_PER_MTOK
                              + _usage_out / 1e6 * PRICE_OUT_PER_MTOK, 6),
            "latency_ms": int(_elapsed * 1000),
            "question": question[:140],
        }
        # Structured stdout line -> collector filelog -> Splunk index
        # nwpay_audit / sourcetype nwpay:cora (pod annotations route it).
        # Feeds the ITSI "AI agents" service KPIs. HEC emit is best-effort
        # belt-and-braces on the same event.
        log.info("cora_ask %s", json.dumps(_ask_event))
        _hec_emit(_ask_event)
        return jsonify({
            "answer": answer,
            "model": _resp_model,
            "mode": mode,
            "usage": {
                "input_tokens": _usage_in,
                "output_tokens": _usage_out,
            },
        })
    except anthropic.APIStatusError as e:
        log.error("anthropic_error status=%s", e.status_code)
        return jsonify({"error": f"anthropic {e.status_code}",
                        "detail": str(getattr(e, "message", ""))[:200]}), 502
    except Exception as e:  # noqa: BLE001
        log.error("cora_error %s", e)
        return jsonify({"error": "internal", "detail": str(e)[:200]}), 500
