// Runtime config — everything the sim needs from the environment, with
// defaults chosen so the in-cluster deployment "just works" and every
// value is overridable via a Deployment env var.
//
// Nothing in here writes to Kubernetes or the SPA; it's pure parsing.

function envStr(name, fallback) {
  const v = process.env[name];
  return typeof v === "string" && v.length > 0 ? v : fallback;
}

function envBool(name, fallback) {
  const v = process.env[name];
  if (v === undefined) return fallback;
  const s = String(v).trim().toLowerCase();
  if (s === "1" || s === "true" || s === "yes" || s === "on") return true;
  if (s === "0" || s === "false" || s === "no" || s === "off") return false;
  return fallback;
}

function envInt(name, fallback) {
  const v = process.env[name];
  if (v === undefined || v === "") return fallback;
  const n = parseInt(v, 10);
  return Number.isFinite(n) ? n : fallback;
}

// The three cities this simulator drives. The persona ids are pinned to
// values that already exist in frontend/src/personas.ts — we intentionally
// do NOT modify that file, so Madrid keeps its country=ES wiring to the
// sanctions-aml chaos gate and the UK/DE trios keep their existing shape.
//
// If someone later adds new personas to the SPA, extend this table (no
// container rebuild needed if the persona.id is passed via env override).
const DEFAULT_CITIES = {
  madrid: {
    label: "Madrid",
    personaId: envStr("MADRID_PERSONA_ID", "cust-es-001"),
    // customer.location comes from personas.ts (Sofía has location=madrid),
    // so the RUM span carries it automatically. Left here so a future
    // persona swap can override without a code edit.
    locationOverride: envStr("MADRID_LOCATION_OVERRIDE", ""),
    countryOverride: envStr("MADRID_COUNTRY_OVERRIDE", ""),
    // Madrid is the only city that branches on chaos state.
    chaosAware: true,
  },
  london: {
    label: "London",
    personaId: envStr("LONDON_PERSONA_ID", "cust-uk-003"),
    // Margaret has no location in personas.ts (a deliberate legacy shape
    // — see personas.ts commentary). The RUM span therefore carries no
    // customer.location for London sessions; Splunk RUM's built-in
    // geoCity/geoCountry (derived from egress IP) is the fallback pivot.
    // Set LONDON_LOCATION_OVERRIDE=london if you also expose SplunkRum on
    // window in the SPA and want the override applied post-init.
    locationOverride: envStr("LONDON_LOCATION_OVERRIDE", ""),
    countryOverride: envStr("LONDON_COUNTRY_OVERRIDE", ""),
    chaosAware: false,
  },
  frankfurt: {
    label: "Frankfurt",
    personaId: envStr("FRANKFURT_PERSONA_ID", "cust-de-001"),
    // Klaus already has location=frankfurt in personas.ts.
    locationOverride: envStr("FRANKFURT_LOCATION_OVERRIDE", ""),
    countryOverride: envStr("FRANKFURT_COUNTRY_OVERRIDE", ""),
    chaosAware: false,
  },
};

function pickEnabledCities() {
  const out = {};
  for (const [key, def] of Object.entries(DEFAULT_CITIES)) {
    const envKey = `CITY_${key.toUpperCase()}_ENABLED`;
    if (envBool(envKey, true)) out[key] = def;
  }
  return out;
}

export const config = {
  // In-cluster SPA URL. The web-frontend Service is a NodePort/ClusterIP
  // at namespace/natwest. Same-origin gateway proxy handles /api and
  // /chaos/api, so a pod loading the SPA sees exactly the same asset +
  // API surface a browser would.
  spaUrl: envStr("SPA_URL", "http://web-frontend.natwest.svc.cluster.local"),

  // Chaos-controller ClusterIP. We deliberately hit it DIRECTLY rather
  // than via the web-frontend /chaos/api reverse-proxy so a hung nginx
  // doesn't blind the sim to real chaos state.
  chaosUrl: envStr(
    "CHAOS_URL",
    "http://chaos-controller.natwest.svc.cluster.local:8080",
  ),
  // Bearer for the chaos-controller. Mounted from the existing
  // chaos-controller-token Secret in helm/rum-user-simulator.yaml.
  chaosToken: envStr("CHAOS_PRESENTER_TOKEN", ""),

  // Scenarios whose "armed" state trips the rage-click / degraded flow
  // in the Madrid session loop. Comma-separated so ops can extend the
  // list live (`kubectl set env deploy/rum-user-simulator
  // MADRID_CHAOS_SCENARIOS=madrid-payment-degradation,...`).
  madridChaosScenarios: envStr(
    "MADRID_CHAOS_SCENARIOS",
    "madrid-payment-degradation,madrid-network-degradation",
  ).split(",").map((s) => s.trim()).filter(Boolean),

  // One session per city per cadenceSeconds. 30 s is dense enough that
  // the DXA per-location conversion rate stabilises within ~2 min but
  // sparse enough that a single-pod sim + Chromium can keep up.
  cadenceSeconds: envInt("CADENCE_SECONDS", 30),

  // Chaos-poll interval. Runs INDEPENDENTLY of the session loop —
  // we cache the last result and each session-loop iteration reads the
  // cache. Keeping it separate means a slow chaos-controller doesn't
  // stretch the per-session budget.
  chaosPollSeconds: envInt("CHAOS_POLL_SECONDS", 5),

  // Per-session soft budget. If the SPA takes longer than this we abandon
  // and try again next tick — better a missed session than an unbounded
  // hang.
  sessionBudgetSeconds: envInt("SESSION_BUDGET_SECONDS", 25),

  // Rage-click config. 6–8 clicks with 100–200ms gaps trips Splunk RUM's
  // built-in Frustration Signals rage-click detector (see rum.ts init).
  rageClickCount: envInt("RAGE_CLICK_COUNT", 7),
  rageClickGapMs: envInt("RAGE_CLICK_GAP_MS", 150),

  // Structured logging toggle. Default is human-readable one-line JSON
  // so `kubectl logs -f` is still easy to scan; flip to plain text if
  // your log pipeline hates JSON.
  logJson: envBool("LOG_JSON", true),

  cities: pickEnabledCities(),
};

export function log(level, msg, extra = {}) {
  const rec = { ts: new Date().toISOString(), level, msg, ...extra };
  if (config.logJson) {
    process.stdout.write(JSON.stringify(rec) + "\n");
  } else {
    process.stdout.write(
      `${rec.ts} [${level}] ${msg} ${JSON.stringify(extra)}\n`,
    );
  }
}
