// PresenterHUD — the on-stage cheat sheet for the operator driving the demo.
//
// Renders a small fixed-position panel in the bottom-right corner of the
// SPA when the URL was loaded with `?presenter=1` (or the same flag is
// sticky in sessionStorage). The HUD surfaces:
//
//   1. Active persona + tier — drives the customer.id / customer.tier
//      RUM attributes and matches the Tag Spotlight pivots in Act II.B.
//   2. Last RUM trace id from the most recent recordPageAction call,
//      with a one-click pivot to the matching APM trace in Splunk
//      Observability Cloud — collapses I.1 -> I.2 from "find the trace"
//      to "click the trace".
//   3. Active incident toggles on the api-gateway pod, polled every 5 s
//      from /api/admin/incident/status. Highlights when ANY chaos var is
//      off baseline so the presenter immediately knows the audience is
//      seeing an injected scenario, not the steady state.
//   4. Two stopwatches — Act I (target 6 min) and Act II (target 12 min)
//      — so the presenter doesn't have to glance at their phone.
//
// The HUD never collects telemetry; it's read-only UI plumbing for the
// person standing in front of the audience. It honours the same
// `?presenter=0` toggle for a fast disable.

import { useEffect, useState } from "react";

import { fetchScenarios } from "../chaos";
import { AppConfig } from "../config";
import { usePersona } from "../PersonaContext";
import { TIER_COLOURS, tierLabel, type Persona } from "../personas";
import { meltdownStoryLabel, STORY_MELTDOWN_PERSONA_ID } from "../storyDemo";
import { LastTrace, getLastTrace, subscribeLastTrace } from "../rum";

interface IncidentStatus {
  service: string;
  tier: string;
  vars: Record<string, string>;
}

// Baseline values that match scripts/incident.sh's DEFAULT_* constants.
// Anything else means the operator has injected a scenario. Keep this in
// sync with scripts/incident.sh — the cost of drifting is a stale "ALL
// CLEAR" indicator on the HUD, not a runtime error.
const BASELINE_VARS: Record<string, string> = {
  ERROR_RATE: "0.05",
  CACHE_HIT_RATE: "0.97",
  DB_LATENCY_MS: "0",
  CPU_REGRESSION_ENABLED: "false",
  TIER_THROTTLE_PROB: "bronze:0.0,silver:0.0,gold:0.0",
};

function isOffBaseline(name: string, value: string): boolean {
  // ERROR_RATE varies by service (0.02 on fraud, 0.05 on swift). The
  // api-gateway is *not* one of those services so its baseline ERROR_RATE
  // is whatever the Helm chart set: any low value (<= 0.06) is fine. We
  // only flag it when an operator has cranked it above demo defaults.
  if (name === "ERROR_RATE") {
    const n = parseFloat(value);
    return !Number.isNaN(n) && n > 0.06;
  }
  const baseline = BASELINE_VARS[name];
  if (baseline === undefined) return false;
  return value !== "" && value !== baseline;
}

// Format ms as mm:ss for the act timers. Negative values clamp to 0.
function formatElapsed(ms: number): string {
  if (ms <= 0) return "00:00";
  const total = Math.floor(ms / 1000);
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

// Splunk Observability APM-trace URL. The realm is the only piece of
// tenant config we need (the rest is a stable path on app.<realm>.signalfx.com).
// Falls back to the trace-id search if the realm isn't configured.
function apmTraceUrl(realm: string | undefined, traceId: string): string {
  if (!realm) {
    return `https://app.signalfx.com/#/apm/traces/${encodeURIComponent(traceId)}`;
  }
  return `https://app.${realm}.signalfx.com/#/apm/traces/${encodeURIComponent(traceId)}`;
}

interface ActTimerState {
  startedAt: number | null; // epoch ms or null when not running
  pausedAt: number | null;  // when paused, snapshot of elapsed
}

const TIMER_INITIAL: ActTimerState = { startedAt: null, pausedAt: null };

function timerLabel(t: ActTimerState, now: number): string {
  if (t.startedAt === null) return "00:00";
  if (t.pausedAt !== null) return formatElapsed(t.pausedAt);
  return formatElapsed(now - t.startedAt);
}

interface Props {
  config: AppConfig;
}

export default function PresenterHUD({ config }: Props) {
  const { persona } = usePersona();
  const [trace, setTrace] = useState<LastTrace | null>(() => getLastTrace());
  const [incident, setIncident] = useState<IncidentStatus | null>(null);
  const [actI, setActI] = useState<ActTimerState>(TIMER_INITIAL);
  const [actII, setActII] = useState<ActTimerState>(TIMER_INITIAL);
  const [now, setNow] = useState<number>(() => Date.now());
  const [collapsed, setCollapsed] = useState<boolean>(false);
  // Armed-scenario count from the chaos-controller catalog. Only
  // polled when ops mode is on AND a chaos token is configured; the
  // HUD silently no-ops otherwise so a non-ops session never makes
  // network calls to /chaos/api/*.
  const [armedScenarios, setArmedScenarios] = useState<number | null>(null);

  // Subscribe to the latest trace id from RUM. We get the current value
  // synchronously (useState initial fn) so the panel doesn't flash empty
  // for a frame after persona switching mid-demo.
  useEffect(() => {
    const unsub = subscribeLastTrace((t) => setTrace(t));
    return unsub;
  }, []);

  // Poll the api-gateway's incident-status endpoint every 5 seconds. The
  // gateway is the only pod that responds with real data (the endpoint
  // returns an empty vars map elsewhere) so this is a cheap, focused
  // probe. The HUD degrades to "status unavailable" if the call fails —
  // we never want a HUD bug to throw inside React's render tree.
  useEffect(() => {
    let cancelled = false;
    async function tick() {
      try {
        const base = config.gatewayUrl.replace(/\/$/, "");
        const res = await fetch(`${base}/admin/incident/status`, {
          method: "GET",
          headers: { Accept: "application/json" },
          credentials: "omit",
        });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const body = (await res.json()) as IncidentStatus;
        if (!cancelled) setIncident(body);
      } catch {
        if (!cancelled) setIncident(null);
      }
    }
    tick();
    const handle = window.setInterval(tick, 5000);
    return () => {
      cancelled = true;
      window.clearInterval(handle);
    };
  }, [config.gatewayUrl]);

  // 1 Hz clock tick so the timers render in real time without each
  // timer having its own setInterval. One coalesced re-render per second
  // is plenty for human-readable mm:ss output.
  useEffect(() => {
    const handle = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(handle);
  }, []);

  // When ops mode is on, poll the chaos catalog so the HUD can show
  // "N scenarios armed" right next to the incident row. We use the
  // same 5 s cadence as the incident endpoint poll to keep network
  // chatter consistent.
  useEffect(() => {
    if (!config.opsMode || !config.chaosToken) {
      setArmedScenarios(null);
      return;
    }
    let cancelled = false;
    let ac = new AbortController();
    async function tick() {
      ac = new AbortController();
      try {
        const data = await fetchScenarios(config, ac.signal);
        if (!cancelled) setArmedScenarios(data.armed_count);
      } catch {
        if (!cancelled) setArmedScenarios(null);
      }
    }
    tick();
    const handle = window.setInterval(tick, 5000);
    return () => {
      cancelled = true;
      ac.abort();
      window.clearInterval(handle);
    };
  }, [config]);

  const tierColour = TIER_COLOURS[persona.tier];
  const offBaseline = incident
    ? Object.entries(incident.vars).filter(([k, v]) => isOffBaseline(k, v))
    : [];

  function toggleTimer(
    state: ActTimerState,
    setter: (s: ActTimerState) => void,
  ) {
    if (state.startedAt === null) {
      setter({ startedAt: Date.now(), pausedAt: null });
    } else if (state.pausedAt !== null) {
      // Resume: shift startedAt so elapsed picks up where it left off.
      setter({ startedAt: Date.now() - state.pausedAt, pausedAt: null });
    } else {
      setter({ ...state, pausedAt: Date.now() - state.startedAt });
    }
  }

  function resetTimer(setter: (s: ActTimerState) => void) {
    setter(TIMER_INITIAL);
  }

  if (collapsed) {
    return (
      <button
        type="button"
        className="presenter-hud__collapsed"
        onClick={() => setCollapsed(false)}
        aria-label="Show presenter HUD"
        title="Show presenter HUD"
      >
        HUD
      </button>
    );
  }

  return (
    <aside className="presenter-hud" aria-label="Presenter HUD">
      <header className="presenter-hud__header">
        <span className="presenter-hud__title">Presenter HUD</span>
        <button
          type="button"
          className="presenter-hud__icon"
          onClick={() => setCollapsed(true)}
          aria-label="Collapse"
          title="Collapse"
        >
          –
        </button>
      </header>

      <PersonaRow persona={persona} tierColour={tierColour} />

      {persona.id === STORY_MELTDOWN_PERSONA_ID && (
        <div className="presenter-hud__row">
          <span className="presenter-hud__label">Story</span>
          <span className="presenter-hud__value presenter-hud__muted">
            {meltdownStoryLabel()}
          </span>
        </div>
      )}

      <TraceRow trace={trace} realm={config.rumRealm} />

      <IncidentRow
        incident={incident}
        offBaseline={offBaseline}
        armedScenarios={armedScenarios}
      />

      <div className="presenter-hud__timers">
        <TimerTile
          name="Act I"
          target="6:00"
          state={actI}
          now={now}
          onToggle={() => toggleTimer(actI, setActI)}
          onReset={() => resetTimer(setActI)}
        />
        <TimerTile
          name="Act II"
          target="12:00"
          state={actII}
          now={now}
          onToggle={() => toggleTimer(actII, setActII)}
          onReset={() => resetTimer(setActII)}
        />
      </div>
    </aside>
  );
}

function PersonaRow({
  persona,
  tierColour,
}: {
  persona: Persona;
  tierColour: { bg: string; fg: string };
}) {
  return (
    <div className="presenter-hud__row">
      <span className="presenter-hud__label">Persona</span>
      <span className="presenter-hud__value">
        <span aria-hidden="true">{persona.avatar}</span> {persona.name}
        <span
          className="tier-chip"
          style={{ background: tierColour.bg, color: tierColour.fg, marginLeft: 6 }}
        >
          {tierLabel(persona.tier)}
        </span>
      </span>
    </div>
  );
}

function TraceRow({ trace, realm }: { trace: LastTrace | null; realm: string | undefined }) {
  if (!trace) {
    return (
      <div className="presenter-hud__row">
        <span className="presenter-hud__label">Last trace</span>
        <span className="presenter-hud__value presenter-hud__muted">
          submit a payment to populate
        </span>
      </div>
    );
  }
  return (
    <div className="presenter-hud__row">
      <span className="presenter-hud__label">Last trace</span>
      <span className="presenter-hud__value">
        <a
          className="presenter-hud__link"
          href={apmTraceUrl(realm, trace.traceId)}
          target="_blank"
          rel="noopener noreferrer"
          title={`${trace.name} — open in Splunk APM`}
        >
          {trace.traceId.slice(0, 12)}…
        </a>
        <span className="presenter-hud__sub"> {trace.name}</span>
      </span>
    </div>
  );
}

function IncidentRow({
  incident,
  offBaseline,
  armedScenarios,
}: {
  incident: IncidentStatus | null;
  offBaseline: Array<[string, string]>;
  // From the chaos-controller catalog poll. ``null`` means the HUD is
  // either not in ops mode or the catalog poll failed; we then fall
  // back to the env-baseline diff exclusively.
  armedScenarios: number | null;
}) {
  if (incident === null && armedScenarios === null) {
    return (
      <div className="presenter-hud__row">
        <span className="presenter-hud__label">Incident</span>
        <span className="presenter-hud__value presenter-hud__muted">status unavailable</span>
      </div>
    );
  }
  if (offBaseline.length === 0 && (armedScenarios === null || armedScenarios === 0)) {
    return (
      <div className="presenter-hud__row">
        <span className="presenter-hud__label">Incident</span>
        <span className="presenter-hud__value presenter-hud__ok">all clear</span>
      </div>
    );
  }
  return (
    <div className="presenter-hud__row presenter-hud__row--alert">
      <span className="presenter-hud__label">Incident</span>
      <div className="presenter-hud__value">
        {armedScenarios !== null && armedScenarios > 0 && (
          <div className="presenter-hud__armed">
            <strong>{armedScenarios}</strong>{" "}
            {armedScenarios === 1 ? "scenario" : "scenarios"} armed
          </div>
        )}
        {offBaseline.length > 0 && (
          <ul className="presenter-hud__incident-list">
            {offBaseline.map(([k, v]) => (
              <li key={k}>
                <code>{k}</code> = <strong>{v}</strong>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}

function TimerTile({
  name,
  target,
  state,
  now,
  onToggle,
  onReset,
}: {
  name: string;
  target: string;
  state: ActTimerState;
  now: number;
  onToggle: () => void;
  onReset: () => void;
}) {
  const running = state.startedAt !== null && state.pausedAt === null;
  return (
    <div className="presenter-hud__timer">
      <div className="presenter-hud__timer-head">
        <span>{name}</span>
        <span className="presenter-hud__sub">target {target}</span>
      </div>
      <div className="presenter-hud__timer-clock">{timerLabel(state, now)}</div>
      <div className="presenter-hud__timer-controls">
        <button type="button" onClick={onToggle}>
          {running ? "Pause" : state.startedAt === null ? "Start" : "Resume"}
        </button>
        <button type="button" onClick={onReset} disabled={state.startedAt === null}>
          Reset
        </button>
      </div>
    </div>
  );
}
