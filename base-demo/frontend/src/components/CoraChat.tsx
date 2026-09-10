// Cora — the AI assistant widget on the Send Money page.
//
// Floating launcher (bottom-right) that opens a chat panel. Questions go
// same-origin to POST /cora/api/ask, which nginx proxies to the
// cora-agent Service; that backend makes a real Anthropic call and its
// gen_ai spans feed Splunk AI Agent Monitoring. If cora-agent is absent
// the proxy 502s and the panel shows a friendly unavailable note.
//
// Demo controls: a small "simulate faulty responses" switch in the panel
// footer sends mode=hallucinate, which the backend answers with fixture
// wrong-answers so the AI-monitoring hallucination evaluator has
// something to flag. Presenter-facing, deliberately understated.
import { FormEvent, useEffect, useRef, useState } from "react";

import { recordPageAction } from "../rum";

interface CoraMessage {
  role: "user" | "cora";
  text: string;
  degraded?: boolean;
}

interface CoraReply {
  answer?: string;
  model?: string;
  mode?: string;
  error?: string;
}

const GREETING: CoraMessage = {
  role: "cora",
  text: "Hi, I'm Cora — I can help with questions about your payments. Ask me anything, for example “why did my payment fail?”",
};

export default function CoraChat() {
  const [open, setOpen] = useState(false);
  const [messages, setMessages] = useState<CoraMessage[]>([GREETING]);
  const [input, setInput] = useState("");
  const [busy, setBusy] = useState(false);
  const [faulty, setFaulty] = useState(false);
  const scrollRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    // Keep the newest message in view as the thread grows.
    const el = scrollRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [messages, busy, open]);

  async function ask(ev: FormEvent) {
    ev.preventDefault();
    const question = input.trim();
    if (!question || busy) return;
    setInput("");
    setMessages((m) => [...m, { role: "user", text: question }]);
    setBusy(true);
    const mode = faulty ? "hallucinate" : "normal";
    try {
      recordPageAction("Ask Cora", { "cora.mode": mode });
    } catch {
      /* RUM not ready — never block the chat on telemetry */
    }
    try {
      const res = await fetch("/cora/api/ask", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ question, mode }),
      });
      const body = (await res.json().catch(() => ({}))) as CoraReply;
      if (!res.ok || !body.answer) {
        throw new Error(body.error || `HTTP ${res.status}`);
      }
      setMessages((m) => [
        ...m,
        { role: "cora", text: body.answer as string, degraded: mode === "hallucinate" },
      ]);
    } catch {
      setMessages((m) => [
        ...m,
        {
          role: "cora",
          text: "Sorry — I can't help right now. Please try again in a moment.",
        },
      ]);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="cora-root">
      {open && (
        <div className="cora-panel" role="dialog" aria-label="Cora assistant">
          <div className="cora-panel__header">
            <span className="cora-avatar" aria-hidden="true">
              C
            </span>
            <div className="cora-panel__title">
              <strong>Cora</strong>
              <span>Your AI payments assistant</span>
            </div>
            <button
              type="button"
              className="cora-close"
              aria-label="Close Cora"
              onClick={() => setOpen(false)}
            >
              &times;
            </button>
          </div>
          <div className="cora-thread" ref={scrollRef}>
            {messages.map((m, i) => (
              <div
                key={i}
                className={`cora-msg cora-msg--${m.role}${m.degraded ? " cora-msg--degraded" : ""}`}
              >
                {m.text}
              </div>
            ))}
            {busy && (
              <div className="cora-msg cora-msg--cora cora-msg--typing" aria-label="Cora is typing">
                <span />
                <span />
                <span />
              </div>
            )}
          </div>
          <form className="cora-input" onSubmit={ask}>
            <input
              type="text"
              value={input}
              placeholder="Ask about your payment…"
              onChange={(e) => setInput(e.target.value)}
              disabled={busy}
              aria-label="Message Cora"
            />
            <button type="submit" className="primary" disabled={busy || !input.trim()}>
              Send
            </button>
          </form>
          <label className="cora-demo-toggle" title="Demo: Cora answers with deliberately incorrect fixture responses so AI monitoring flags them">
            <input
              type="checkbox"
              checked={faulty}
              onChange={(e) => setFaulty(e.target.checked)}
            />
            <span>Simulate faulty responses</span>
          </label>
        </div>
      )}
      <button
        type="button"
        className="cora-launcher"
        onClick={() => setOpen((o) => !o)}
        aria-expanded={open}
        aria-label={open ? "Close Cora assistant" : "Open Cora assistant"}
      >
        <span className="cora-avatar" aria-hidden="true">
          C
        </span>
        Ask Cora
      </button>
    </div>
  );
}
