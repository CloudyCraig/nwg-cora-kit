// Presenter control for the Cora AI background traffic stream.
//
// The cora-loadgen deployment generates a steady stream of real Cora
// questions (and a burst with hallucinations while a Madrid scenario is
// armed). Each normal question is a real Anthropic API call, so the
// stream is presenter-switchable: this card reads and writes
// /cora/api/traffic-config (nginx -> cora-agent), which the loadgen
// polls every ~15s. State survives page reloads (it lives server-side);
// a cora-agent restart returns to the CORA_TRAFFIC_DEFAULT env setting.
import { useCallback, useEffect, useState } from "react";

export default function CoraTrafficCard() {
  const [enabled, setEnabled] = useState<boolean | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      const res = await fetch("/cora/api/traffic-config");
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const body = (await res.json()) as { enabled?: boolean };
      setEnabled(Boolean(body.enabled));
      setError(null);
    } catch {
      setEnabled(null);
      setError("Cora traffic control unavailable");
    }
  }, []);

  useEffect(() => {
    void refresh();
    const t = window.setInterval(() => void refresh(), 20_000);
    return () => window.clearInterval(t);
  }, [refresh]);

  const toggle = async () => {
    if (busy || enabled === null) return;
    setBusy(true);
    try {
      const res = await fetch("/cora/api/traffic-config", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ enabled: !enabled }),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const body = (await res.json()) as { enabled?: boolean };
      setEnabled(Boolean(body.enabled));
      setError(null);
    } catch {
      setError("Could not update Cora traffic");
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="chaos-section cora-traffic">
      <h2 className="chaos-section__title">AI assistant traffic</h2>
      <div className="chaos-grid">
        <article
          className={`chaos-card${enabled ? " chaos-card--armed" : ""}`}
        >
          <header className="cora-traffic__head">
            <h3>Cora background traffic</h3>
            <span
              className={`cora-traffic__pill${enabled ? " cora-traffic__pill--on" : ""}`}
            >
              {enabled === null ? "—" : enabled ? "STREAMING" : "OFF"}
            </span>
          </header>
          <p className="cora-traffic__desc">
            Steady stream of customer questions to the Cora AI assistant
            (~2/min; surges with hallucinations while a Madrid scenario is
            armed). Uses real Anthropic API calls — switch off outside
            demo sessions.
          </p>
          {error && <p className="cora-traffic__error">{error}</p>}
          <button
            type="button"
            className="btn-primary"
            onClick={() => void toggle()}
            disabled={busy || enabled === null}
          >
            {busy
              ? "Switching…"
              : enabled
                ? "Stop AI traffic"
                : "Start AI traffic"}
          </button>
        </article>
      </div>
    </section>
  );
}
