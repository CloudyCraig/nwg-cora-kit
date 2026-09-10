// Presenter-only Chaos Dashboard. Routed at /ops, gated by
// config.opsMode (sticky `?ops=1`). Backed by the chaos-controller
// microservice at /chaos/api/* via the web-frontend nginx reverse
// proxy. Every mutation requires the X-Chaos-Token header (sourced
// from config.chaosToken) AND emits a `nwpay:chaos` HEC audit event
// in the same shape scripts/incident.sh produces, so the existing
// SIEM correlation searches keep firing.
//
// UX rules:
//   * Refresh the catalog every 5 s (in-flight requests cancelled).
//   * Group scenarios by category: story / app / latency / tier / infra.
//   * Confirmation modal for any scenario with requires_confirmation
//     (every infra-outage scenario in the catalog has this set).
//   * Parameterised scenarios (tier-throttle, kill-service) render a
//     small select before the Inject button.
//   * A global "Recover all" button calls /chaos/api/recover.
//
// Error handling: any HTTP error is surfaced as an inline message on
// the corresponding card, and the catalog is re-fetched on the next
// poll. The dashboard NEVER crashes the SPA on a backend error.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import CoraTrafficCard from "../components/CoraTrafficCard";

import {
  ChaosApiError,
  ScenarioCatalog,
  ScenarioMeta,
  clearScenario,
  fetchScenarios,
  injectScenario,
  recoverAll,
} from "../chaos";
import { AppConfig } from "../config";
import { useAuth } from "../AuthContext";
import { recordPageAction } from "../rum";

interface OpsProps {
  config: AppConfig;
}

interface PendingAction {
  scenarioId: string;
  action: "inject" | "clear";
  params: Record<string, unknown> | null;
  // For Inject + requires_confirmation scenarios.
  confirmDeadline?: number;
}

// "story" first so the headline multi-act demo sits at the top of the
// dashboard - it's the one operators click most often when running the
// 6-minute customer walkthrough. The single-act categories follow in
// the original order for backward compatibility with operator muscle
// memory.
const CATEGORY_ORDER: ScenarioMeta["category"][] = [
  "story",
  "app",
  "latency",
  "tier",
  "infra",
];

const CATEGORY_TITLES: Record<ScenarioMeta["category"], string> = {
  story: "Customer stories (multi-act)",
  app: "Application errors",
  latency: "Latency",
  tier: "Customer tier",
  infra: "Infrastructure outages",
};

const CATEGORY_SUMMARIES: Record<ScenarioMeta["category"], string> = {
  story:
    "One-click orchestrators that chain multiple scenarios with shared story_id auditing. " +
    "Confirmation required - they mutate the cluster for several minutes and auto-recover.",
  app: "Error rates, scheme errors, async producer / cache toggles.",
  latency: "DB and tail latency, CPU regressions, gateway timeouts.",
  tier: "Per-tier throttling, fast-path bias, cache cold start.",
  infra: "Scale-to-zero outages and pod restarts. Confirmation required.",
};

// Mirror of OPS_STORAGE_KEY in config.ts. Kept inline rather than
// imported to avoid a circular import (config.ts is imported by every
// page; this page is imported by config.ts's consumer App.tsx).
const OPS_STORAGE_KEY = "natwest.demo.ops";

export default function Ops({ config }: OpsProps) {
  const { username } = useAuth();
  const operator = username || "ops-dashboard";

  // Persist opsMode in sessionStorage so the PresenterHUD picks up the
  // chaos-armed counter on its next render without the operator having
  // to type ?ops=1. The /ops route itself is gated on
  // config.chaosToken (see App.tsx) - this flag is for HUD plumbing
  // only.
  useEffect(() => {
    try {
      window.sessionStorage.setItem(OPS_STORAGE_KEY, "1");
    } catch {
      // sessionStorage unavailable (very old WebView / private mode).
      // The dashboard still works; only the HUD counter is degraded.
    }
  }, []);

  const [catalog, setCatalog] = useState<ScenarioCatalog | null>(null);
  const [loading, setLoading] = useState(true);
  const [catalogError, setCatalogError] = useState<string | null>(null);
  const [busy, setBusy] = useState<Record<string, boolean>>({});
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [paramSelections, setParamSelections] = useState<
    Record<string, string>
  >({});
  const [pending, setPending] = useState<PendingAction | null>(null);
  const [recoverBusy, setRecoverBusy] = useState(false);

  const abortRef = useRef<AbortController | null>(null);

  const fetchCatalog = useCallback(async () => {
    abortRef.current?.abort();
    const ac = new AbortController();
    abortRef.current = ac;
    try {
      const result = await fetchScenarios(config, ac.signal);
      setCatalog(result);
      setCatalogError(null);
    } catch (err) {
      if (ac.signal.aborted) return;
      if (err instanceof ChaosApiError) {
        if (err.status === 401) {
          setCatalogError(
            config.chaosToken
              ? "401 from chaos-controller: presenter token mismatch. Run scripts/05c-chaos-controller.sh (or kubectl rollout restart deploy/web-frontend -n natwest) to sync /config.js with the controller."
              : "Chaos dashboard unavailable: no presenter token in /config.js. Run scripts/05c-chaos-controller.sh to enable the chaos-controller and inject the token.",
          );
        } else {
          setCatalogError(err.message);
        }
      } else {
        setCatalogError(
          err instanceof Error ? err.message : "failed to load catalog",
        );
      }
    } finally {
      if (!ac.signal.aborted) {
        setLoading(false);
      }
    }
  }, [config]);

  useEffect(() => {
    fetchCatalog();
    const handle = window.setInterval(() => {
      fetchCatalog();
    }, 5000);
    return () => {
      window.clearInterval(handle);
      abortRef.current?.abort();
    };
  }, [fetchCatalog]);

  // Initialise the parameter selection map once we have the catalog.
  useEffect(() => {
    if (!catalog) return;
    setParamSelections((prev) => {
      const next = { ...prev };
      for (const scn of catalog.scenarios) {
        if (
          scn.param &&
          !(scn.id in next) &&
          scn.param.default !== undefined
        ) {
          next[scn.id] = scn.param.default;
        }
      }
      return next;
    });
  }, [catalog]);

  const grouped = useMemo(() => {
    const buckets: Record<ScenarioMeta["category"], ScenarioMeta[]> = {
      story: [],
      app: [],
      latency: [],
      tier: [],
      infra: [],
    };
    if (catalog) {
      for (const scn of catalog.scenarios) {
        // Defensive against backend introducing a new category before
        // the SPA knows about it: skip rather than crash. The next
        // catalog poll after a frontend deploy will pick it up.
        const bucket = buckets[scn.category];
        if (bucket) bucket.push(scn);
      }
    }
    return buckets;
  }, [catalog]);

  function setError(scenarioId: string, message: string | null) {
    setErrors((prev) => {
      if (message === null) {
        const { [scenarioId]: _drop, ...rest } = prev;
        return rest;
      }
      return { ...prev, [scenarioId]: message };
    });
  }

  function buildParams(scn: ScenarioMeta): Record<string, unknown> | null {
    if (!scn.param) return null;
    const value = paramSelections[scn.id] ?? scn.param.default ?? "";
    if (!value) return null;
    return { [scn.param.name]: value };
  }

  async function runInject(scn: ScenarioMeta, params: Record<string, unknown> | null) {
    setBusy((prev) => ({ ...prev, [scn.id]: true }));
    setError(scn.id, null);
    // Stamp the operator-side click marker BEFORE the network call so
    // the RUM event lands in the session timeline at the moment the
    // click happened, regardless of how long the controller takes to
    // ack. The matching server-side `nwpay:chaos` HEC audit event is
    // still the source of truth for the SIEM correlation searches in
    // ITSI; this RUM event is the browser-side breadcrumb that lets
    // operator-usage analytics work without grepping audit logs.
    const startedAt = performance.now();
    recordPageAction("chaos.action.requested", {
      "chaos.action": "inject",
      "chaos.scenario": scn.id,
      "chaos.category": scn.category,
      "chaos.target_service": scn.target_service,
      "chaos.severity": scn.severity,
      "chaos.requires_confirmation": scn.requires_confirmation,
    });
    try {
      await injectScenario(config, scn.id, params, operator);
      // Refresh catalog so the status pill flips quickly. The next
      // 5 s poll would also pick it up, but this gives instant feedback.
      fetchCatalog();
      recordPageAction("chaos.action.requested", {
        "chaos.action": "inject",
        "chaos.scenario": scn.id,
        "chaos.outcome": "success",
        "client.duration_ms": Math.round(performance.now() - startedAt),
      });
    } catch (err) {
      if (err instanceof ChaosApiError) {
        setError(scn.id, err.message);
      } else if (err instanceof Error) {
        setError(scn.id, err.message);
      } else {
        setError(scn.id, "inject failed");
      }
      recordPageAction("chaos.action.requested", {
        "chaos.action": "inject",
        "chaos.scenario": scn.id,
        "chaos.outcome": "error",
        "client.duration_ms": Math.round(performance.now() - startedAt),
        "error.message": err instanceof Error ? err.message : String(err),
      });
    } finally {
      setBusy((prev) => {
        const { [scn.id]: _drop, ...rest } = prev;
        return rest;
      });
    }
  }

  async function runClear(scn: ScenarioMeta) {
    setBusy((prev) => ({ ...prev, [scn.id]: true }));
    setError(scn.id, null);
    const startedAt = performance.now();
    recordPageAction("chaos.action.requested", {
      "chaos.action": "clear",
      "chaos.scenario": scn.id,
      "chaos.category": scn.category,
      "chaos.target_service": scn.target_service,
      "chaos.severity": scn.severity,
    });
    try {
      await clearScenario(config, scn.id, operator);
      fetchCatalog();
      recordPageAction("chaos.action.requested", {
        "chaos.action": "clear",
        "chaos.scenario": scn.id,
        "chaos.outcome": "success",
        "client.duration_ms": Math.round(performance.now() - startedAt),
      });
    } catch (err) {
      if (err instanceof ChaosApiError) {
        setError(scn.id, err.message);
      } else if (err instanceof Error) {
        setError(scn.id, err.message);
      } else {
        setError(scn.id, "clear failed");
      }
      recordPageAction("chaos.action.requested", {
        "chaos.action": "clear",
        "chaos.scenario": scn.id,
        "chaos.outcome": "error",
        "client.duration_ms": Math.round(performance.now() - startedAt),
        "error.message": err instanceof Error ? err.message : String(err),
      });
    } finally {
      setBusy((prev) => {
        const { [scn.id]: _drop, ...rest } = prev;
        return rest;
      });
    }
  }

  function handleInjectClick(scn: ScenarioMeta) {
    const params = buildParams(scn);
    if (scn.requires_confirmation) {
      setPending({
        scenarioId: scn.id,
        action: "inject",
        params,
        confirmDeadline: Date.now() + 5000,
      });
      return;
    }
    runInject(scn, params);
  }

  async function handleRecoverAll() {
    setRecoverBusy(true);
    const startedAt = performance.now();
    // chaos.scenario = "__recover_all__" is a stable sentinel so the
    // Tag Spotlight pivot has a single bucket to count "recover all"
    // clicks separately from per-scenario clears.
    recordPageAction("chaos.action.requested", {
      "chaos.action": "recover_all",
      "chaos.scenario": "__recover_all__",
      "chaos.category": "infra",
    });
    try {
      await recoverAll(config, operator);
      fetchCatalog();
      recordPageAction("chaos.action.requested", {
        "chaos.action": "recover_all",
        "chaos.scenario": "__recover_all__",
        "chaos.outcome": "success",
        "client.duration_ms": Math.round(performance.now() - startedAt),
      });
    } catch (err) {
      setCatalogError(
        err instanceof Error ? err.message : "recover failed",
      );
      recordPageAction("chaos.action.requested", {
        "chaos.action": "recover_all",
        "chaos.scenario": "__recover_all__",
        "chaos.outcome": "error",
        "client.duration_ms": Math.round(performance.now() - startedAt),
        "error.message": err instanceof Error ? err.message : String(err),
      });
    } finally {
      setRecoverBusy(false);
    }
  }

  return (
    <div className="ops-page">
      {/*
        Banner is a single inline row: title on the left, armed-count
        chip + Recover-all button on the right. The previous "Actions
        here mutate the live cluster..." paragraph was removed at user
        request - the same information is preserved as documentation
        in scripts/incident.sh (PREFERRED INTERFACE block) and on the
        nav-link--ops tooltip, so the audit story isn't lost.
      */}
      <header className="ops-banner" role="alert">
        <h1>Demo controls — chaos dashboard</h1>
        <div className="ops-banner__actions">
          <div className="ops-banner__stat">
            <span className="ops-banner__stat-value">
              {catalog ? catalog.armed_count : "—"}
            </span>
            <span className="ops-banner__stat-label">scenarios armed</span>
          </div>
          <button
            type="button"
            className="btn-primary ops-banner__recover"
            onClick={handleRecoverAll}
            disabled={recoverBusy || loading}
          >
            {recoverBusy ? "Recovering…" : "Recover all"}
          </button>
        </div>
      </header>

      {catalogError && (
        <div className="ops-error" role="status">
          {catalogError}
        </div>
      )}

      <CoraTrafficCard />

      {loading && !catalog && (
        <div className="ops-loading">Loading scenarios…</div>
      )}

      {CATEGORY_ORDER.map((cat) => {
        const items = grouped[cat];
        if (!items || items.length === 0) return null;
        return (
          <section className="chaos-section" key={cat}>
            <header>
              <h2>{CATEGORY_TITLES[cat]}</h2>
              <p>{CATEGORY_SUMMARIES[cat]}</p>
            </header>
            <div className="chaos-grid">
              {items.map((scn) => (
                <ChaosCard
                  key={scn.id}
                  scenario={scn}
                  busy={Boolean(busy[scn.id])}
                  error={errors[scn.id] ?? null}
                  paramValue={paramSelections[scn.id] ?? ""}
                  onParamChange={(v) =>
                    setParamSelections((prev) => ({ ...prev, [scn.id]: v }))
                  }
                  onInject={() => handleInjectClick(scn)}
                  onClear={() => runClear(scn)}
                />
              ))}
            </div>
          </section>
        );
      })}

      {pending && (
        <ConfirmationModal
          pending={pending}
          scenario={catalog?.scenarios.find((s) => s.id === pending.scenarioId)}
          onCancel={() => setPending(null)}
          onConfirm={(scn) => {
            setPending(null);
            runInject(scn, pending.params);
          }}
        />
      )}
    </div>
  );
}

function severityClass(severity: ScenarioMeta["severity"]): string {
  switch (severity) {
    case "high":
      return "chaos-card__severity chaos-card__severity--high";
    case "medium":
      return "chaos-card__severity chaos-card__severity--medium";
    default:
      return "chaos-card__severity chaos-card__severity--low";
  }
}

function stateLabel(state: ScenarioMeta["status"]["state"]): string {
  switch (state) {
    case "armed":
      return "Armed";
    case "clear":
      return "Clear";
    default:
      return "Unknown";
  }
}

function stateClass(state: ScenarioMeta["status"]["state"]): string {
  switch (state) {
    case "armed":
      return "status-pill status-pill--armed";
    case "clear":
      return "status-pill status-pill--clear";
    default:
      return "status-pill status-pill--unknown";
  }
}

function ChaosCard({
  scenario,
  busy,
  error,
  paramValue,
  onParamChange,
  onInject,
  onClear,
}: {
  scenario: ScenarioMeta;
  busy: boolean;
  error: string | null;
  paramValue: string;
  onParamChange: (value: string) => void;
  onInject: () => void;
  onClear: () => void;
}) {
  const isArmed = scenario.status.state === "armed";
  // Clear is always rendered (user request: uniform UI across all cards,
  // including infra-tier outages that are confirmation-gated). The button
  // is disabled below when isArmed is false so a stray click on a clean
  // scenario can't fire a no-op kubectl scale / set env. pod-restart-
  // gateway is a transient one-shot (k8s recreates the pod immediately),
  // so its status() always returns "clear" - the Clear button stays
  // permanently disabled with a tooltip explaining why.
  const isTransient = scenario.id === "pod-restart-gateway";
  const clearTitle = isTransient
    ? "Transient action — Kubernetes auto-recreates the pod, nothing to clear"
    : isArmed
      ? "Revert this scenario to its baseline"
      : "Nothing to clear — scenario is already at baseline";

  return (
    <article
      className={
        "chaos-card" +
        (scenario.requires_confirmation ? " chaos-card--danger" : "") +
        (isArmed ? " chaos-card--armed" : "")
      }
    >
      {/*
        Head: severity + state pills on a row of their own at the top of
        the card, so the title underneath gets the full card width to
        wrap into. Previously the pills were a flex sibling of the
        title, which squeezed long names like "SWIFT counterparty flap"
        into 3-line columns when the cards were narrow.
      */}
      <header className="chaos-card__head">
        <div className="chaos-card__pills">
          <span className={severityClass(scenario.severity)}>
            {scenario.severity}
          </span>
          <span className={stateClass(scenario.status.state)}>
            {stateLabel(scenario.status.state)}
          </span>
        </div>
        {/*
          Title row: name + info icon. The narrative paragraph used to
          live as a multi-line <p> right under the header, which made
          the orchestrator cards (with their long talk-track narratives)
          dominate the card height and squeezed everything else into a
          tall narrow column - see screenshot 2026-06-09 of the payment-
          meltdown card for the failure mode. Moving the narrative into
          a hover/focus tooltip on a small info icon keeps the card
          compact and balanced, and the operator can still read the
          full text on demand (mouse hover, keyboard focus, or a tap
          on a touch device - all three trigger the popup via :hover +
          :focus + :focus-within selectors in styles.css).
        */}
        <div className="chaos-card__title-row">
          <h3>{scenario.name}</h3>
          <button
            type="button"
            className="chaos-card__info"
            // Title attribute provides the native browser tooltip as a
            // graceful fallback for screen-readers and for browsers that
            // suppress the custom tooltip (e.g. high-contrast modes).
            // Aria-label gives assistive tech a complete sentence rather
            // than just "i".
            title={scenario.narrative}
            aria-label={`About ${scenario.name}: ${scenario.narrative}`}
          >
            <span aria-hidden="true" className="chaos-card__info-glyph">i</span>
            {/* Tooltip body. role=tooltip + the parent button's
                aria-label keep screen-reader output clean - tooltip
                text isn't repeated twice. */}
            <span className="chaos-card__tooltip" role="tooltip">
              {scenario.narrative}
            </span>
          </button>
        </div>
        <p className="chaos-card__target">
          <code>{scenario.target_service}</code>
        </p>
      </header>

      {/*
        Orchestrator progress block. Only renders when the catalog
        returns the shape produced by MeltdownRunner.status() (phase
        present in observed). Single-act scenarios have no `phase`
        field so this block stays hidden for them - no special-casing
        needed in ChaosCard's prop type.
      */}
      <ChaosProgressBlock scenario={scenario} />

      {scenario.param && (
        <label className="chaos-card__param">
          <span>{scenario.param.label}</span>
          {scenario.param.type === "select" && scenario.param.options ? (
            <select
              value={paramValue}
              onChange={(e) => onParamChange(e.target.value)}
              disabled={busy}
            >
              {scenario.param.options.map((opt) => (
                <option key={opt} value={opt}>
                  {opt}
                </option>
              ))}
            </select>
          ) : (
            <input
              type="text"
              value={paramValue}
              onChange={(e) => onParamChange(e.target.value)}
              disabled={busy}
            />
          )}
        </label>
      )}

      {/*
        Footer block: Watch/recovery sits immediately above the Inject /
        Clear row, and both are pushed to the bottom of the card with
        margin-top: auto on the wrapper (see .chaos-card__footer in
        styles.css). Cards with short narratives now look visually
        balanced rather than leaving Watch/recovery floating in
        whitespace.
      */}
      <div className="chaos-card__footer">
        <details className="chaos-card__details">
          <summary>Watch / recovery</summary>
          <p>
            <strong>Watch:</strong> {scenario.watch}
          </p>
          <p>
            <strong>Recovery:</strong> {scenario.recovery_hint}
          </p>
        </details>

        <div className="chaos-card__actions">
          <button
            type="button"
            className="btn-primary"
            onClick={onInject}
            disabled={busy}
          >
            {busy ? "Working…" : "Inject"}
          </button>
          <button
            type="button"
            className="btn-secondary"
            onClick={onClear}
            disabled={busy || !isArmed || isTransient}
            title={clearTitle}
            aria-label={clearTitle}
          >
            Clear
          </button>
        </div>
      </div>

      {error && (
        <div className="chaos-card__error" role="alert">
          {error}
        </div>
      )}
    </article>
  );
}

// ---------------------------------------------------------------------------
// Progress block for orchestrator-style scenarios. Reads phase/elapsed/
// remaining out of the runner's status().observed payload and renders a
// compact "Act 1/2 - 03:12 / 04:00, ~02:48 remaining" line plus the
// story_id so the operator can copy/paste it into a Splunk search.
//
// All fields are optional - if the backend hasn't sent the orchestrator
// shape (i.e. this is a regular single-act scenario) the component
// returns null and contributes no DOM.
// ---------------------------------------------------------------------------
function ChaosProgressBlock({ scenario }: { scenario: ScenarioMeta }) {
  const observed = scenario.status.observed as Record<string, unknown> | undefined;
  if (!observed) return null;

  const phase = typeof observed.phase === "string" ? observed.phase : null;
  if (!phase) return null;

  const storyId =
    typeof observed.story_id === "string" ? observed.story_id : null;
  const elapsedTotal = numericOr(observed.elapsed_total_s, 0);
  const elapsedPhase = numericOr(observed.elapsed_phase_s, 0);
  const remainingPhase = numericOr(observed.remaining_phase_s, 0);
  const lastError =
    typeof observed.last_error === "string" ? observed.last_error : null;

  // Idle/complete is the resting state - show story_id + recap if we
  // have it, otherwise render nothing (regular scenarios won't even
  // have a phase field, but the meltdown will report idle initially).
  const isResting = phase === "idle" || phase === "complete";

  return (
    <div className="chaos-card__progress" aria-live="polite">
      <div className="chaos-card__progress-line">
        <span className="chaos-card__progress-phase">
          {phaseLabel(phase)}
        </span>
        {!isResting && (
          <span className="chaos-card__progress-timing">
            {formatMmSs(elapsedPhase)} elapsed, ~{formatMmSs(remainingPhase)} remaining
            {" "}
            <span className="chaos-card__progress-total">
              (total {formatMmSs(elapsedTotal)})
            </span>
          </span>
        )}
      </div>
      {storyId && (
        <div className="chaos-card__progress-line chaos-card__progress-meta">
          <span>
            story_id <code>{storyId}</code>
          </span>
        </div>
      )}
      {lastError && (
        <div className="chaos-card__progress-error" role="alert">
          last error: {lastError}
        </div>
      )}
    </div>
  );
}

function numericOr(value: unknown, fallback: number): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return fallback;
}

function formatMmSs(seconds: number): string {
  const safe = Math.max(0, Math.floor(seconds));
  const mm = Math.floor(safe / 60).toString().padStart(2, "0");
  const ss = (safe % 60).toString().padStart(2, "0");
  return `${mm}:${ss}`;
}

function phaseLabel(phase: string): string {
  switch (phase) {
    case "act1-db-slow":
      return "Act 1 / 2 — db-slow";
    case "act2-postgres-outage":
      return "Act 2 / 2 — postgres outage";
    case "recovering":
      return "Recovering";
    case "complete":
      return "Last run: complete";
    case "idle":
      return "Idle";
    default:
      return phase;
  }
}

function ConfirmationModal({
  pending,
  scenario,
  onCancel,
  onConfirm,
}: {
  pending: PendingAction;
  scenario: ScenarioMeta | undefined;
  onCancel: () => void;
  onConfirm: (scn: ScenarioMeta) => void;
}) {
  if (!scenario) {
    return null;
  }
  return (
    <div
      className="chaos-modal"
      role="dialog"
      aria-modal="true"
      aria-labelledby="chaos-modal-title"
    >
      <div className="chaos-modal__panel">
        <h2 id="chaos-modal-title">Confirm: {scenario.name}</h2>
        <p className="chaos-modal__lead">
          This will mutate <code>{scenario.target_service}</code> in the
          live cluster.
        </p>
        <ul className="chaos-modal__list">
          <li>
            <strong>Action:</strong> {pending.action}
          </li>
          {pending.params && Object.keys(pending.params).length > 0 && (
            <li>
              <strong>Parameters:</strong>{" "}
              <code>{JSON.stringify(pending.params)}</code>
            </li>
          )}
          <li>
            <strong>Recovery:</strong> {scenario.recovery_hint}
          </li>
        </ul>
        <div className="chaos-modal__actions">
          <button type="button" className="btn-secondary" onClick={onCancel}>
            Cancel
          </button>
          <button
            type="button"
            className="btn-primary chaos-modal__confirm"
            onClick={() => onConfirm(scenario)}
          >
            Confirm and inject
          </button>
        </div>
      </div>
      <div
        className="chaos-modal__backdrop"
        onClick={onCancel}
        aria-hidden="true"
      />
    </div>
  );
}
