import SplunkRum from "@splunk/otel-web";
import SplunkSessionRecorder from "@splunk/otel-web-session-recorder";

import { emitNetworkBeacon } from "./api";
import { AppConfig } from "./config";
import { Persona, findPersona } from "./personas";

// Persona localStorage key duplicated here so rum.ts stays a leaf in the
// import graph (PersonaContext.tsx is the writer and source of truth).
// Best-effort read - if the value is missing or malformed we beacon
// without persona context, which the gateway tolerates.
const PERSONA_STORAGE_KEY = "natwest-demo-persona";

// Tracks whether initRum() has run successfully. setRumPersona() is a no-op
// before this flips, which keeps it safe to call from a React effect that
// runs at PersonaProvider mount on first page load (initRum runs in main.tsx
// before React mounts, so on real navigation the flag is already true).
let rumReady = false;

// Initialise the Splunk RUM browser SDK before React renders so that
// document-load, paint and resource spans are captured. The SDK's fetch
// auto-instrumentation adds the W3C `traceparent` header to same-origin
// requests *and* to any host listed in `propagateTraceHeaderCorsUrls`,
// which is what links the browser RUM trace into the api-gateway APM
// trace when the frontend calls a different origin.
export function initRum(config: AppConfig): void {
  if (!config.rumAccessToken) {
    // eslint-disable-next-line no-console
    console.info("[rum] no token configured, skipping initialisation");
    return;
  }

  // Trust list for cross-origin trace header propagation. Same-origin
  // requests always get traceparent; we add the gateway origin (when
  // it's a different host) so the browser RUM trace links into APM.
  const propagateTo: (string | RegExp)[] = [/^\//];
  try {
    const gw = new URL(config.gatewayUrl, window.location.origin);
    if (gw.origin !== window.location.origin) {
      propagateTo.push(gw.origin);
    }
  } catch {
    // gatewayUrl is relative; same-origin already covers it.
  }

  SplunkRum.init({
    realm: config.rumRealm,
    rumAccessToken: config.rumAccessToken,
    applicationName: config.applicationName,
    deploymentEnvironment: config.deploymentEnvironment,
    version: "0.1.0",
    // Splunk Digital Experience Analytics (DXA) lights up off the
    // anonymous user id stamped onto every span by the v2+ SDK. The
    // value is the default in v2 but we set it explicitly so the demo
    // intent is visible in code review and so the behaviour survives a
    // future minor-version default flip.
    user: { trackingMode: "anonymousTracking" },
    instrumentations: {
      fetch: { propagateTraceHeaderCorsUrls: propagateTo },
      xhr: { propagateTraceHeaderCorsUrls: propagateTo },
      // Frustration Signals power the DXA "User frustration" tab.
      // Rage clicks are on by default in v2.2+; opt the demo into the
      // dead-click and error-click detectors as well so a chaos-injected
      // 5xx storm or a frozen submit button shows up as a discrete
      // frustration span the audience can pivot on.
      frustrationSignals: {
        rageClick: true,
        deadClick: true,
        errorClick: true,
      },
    },
  });

  SplunkSessionRecorder.init({
    realm: config.rumRealm,
    rumAccessToken: config.rumAccessToken,
  });

  rumReady = true;

  // Persist the channel dimension on every RUM event from this session so
  // Splunk Observability's "channel" Tag Spotlight breakdown lights up
  // the moment the mobile-shaped variant is hit. Same dimension is also
  // baked into the gateway payload via api.ts::buildSamplePayment so APM
  // spans carry it end-to-end.
  try {
    SplunkRum.setGlobalAttributes({
      "channel": config.channel,
      "app.name": config.applicationName,
    });
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn("[rum] failed to set channel global attribute", err);
  }
}

// Push customer.id / customer.tier onto every subsequent RUM event for this
// session. Splunk RUM exposes setGlobalAttributes for exactly this case, and
// the resource module on the Web SDK forwards them onto every span.
//
// Called from PersonaContext on persona change so the audience can see the
// "Sessions by tier" pivot light up live during the demo. When the persona
// carries a location (EU personas), customer.location / customer.country /
// customer.region get pushed onto the same session attributes so the RUM
// "Sessions by geography" pivot lights up with the same data the gateway
// span carries.
export function setRumPersona(persona: Persona): void {
  if (!rumReady) return;
  try {
    // The demo's original NatWest-specific attribute set. Kept as-is so
    // existing dashboards / Tag Spotlight pivots / saved searches that
    // group on `customer.tier` / `customer.location` continue to work
    // unchanged.
    const attrs: Record<string, string | number> = {
      "customer.id": persona.id,
      "customer.tier": persona.tier,
      "customer.name": persona.name,
    };
    if (persona.location) {
      attrs["customer.location"] = persona.location.city;
      attrs["customer.country"] = persona.location.country;
      attrs["customer.region"] = persona.location.region;
      attrs["customer.lat"] = persona.location.lat;
      attrs["customer.lon"] = persona.location.lon;
    }

    // OTel-semantic aliases for the same identity, emitted alongside
    // the NatWest-specific keys. The Path-to-Green assessment
    // explicitly recommends Splunk's `enduser.id` / `enduser.role` /
    // (custom) `enduser.name` attributes - having them present means a
    // customer can pivot RUM Sessions by either naming convention
    // without us having to migrate every consumer first. Reference:
    // https://opentelemetry.io/docs/specs/semconv/general/attributes/#general-identity-attributes
    //
    // `enduser.role` carries the persona tier (gold/silver/bronze) as
    // an authorisation-level proxy, which matches the OTel guidance
    // ("Role of the user, e.g. admin, user, guest"). For a real
    // banking client `enduser.role` would be the customer's product
    // tier or staff role; we use tier because that is what segments
    // the demo's narratives.
    attrs["enduser.id"]   = persona.id;
    attrs["enduser.role"] = persona.tier;
    attrs["enduser.name"] = persona.name;

    SplunkRum.setGlobalAttributes(attrs);
  } catch (err) {
    // The SDK throws if it has been destroyed (e.g. in HMR teardown). Don't
    // let that break the SPA - persona switching is best-effort for RUM.
    // eslint-disable-next-line no-console
    console.warn("[rum] setGlobalAttributes failed", err);
  }
}

// ---- degraded-payment RUM signal -------------------------------------------
// A successful-but-slow payment (or a hard failure) is reported to Splunk RUM
// as a first-class error event AND stamps `payment.degraded=true` as a session
// global. This is what makes the Madrid / ES sanctions-aml degradation show up
// reliably in RUM Session Search. The backend returns a slow HTTP 200 (the
// sanctions-aml 500 is absorbed by the gateway's downstream fan-out), so
// without this the browser session carries no error and the "Issues" column
// stays empty even though the trace is fully degraded. A degraded ES payment
// runs ~2.3 s vs ~80 ms baseline, so a latency threshold cleanly separates the
// two. The APM trace (sanctions-aml red root cause) is untouched — this only
// adds the RUM-side flag so the session is trivial to find and drill into.
export const DEGRADED_PAYMENT_CLIENT_MS = 1200;

export function reportPaymentDegraded(detail: {
  reason: "slow" | "error";
  durationMs: number;
  scheme?: string;
  country?: string;
  location?: string;
  tier?: string;
  message?: string;
}): void {
  if (!rumReady) return;
  // Sticky session marker so Session Search can filter the whole session with
  // `payment.degraded = true` (100% precision, alongside the Issues badge).
  try {
    SplunkRum.setGlobalAttributes({ "payment.degraded": "true" });
  } catch {
    // best-effort; the Issues badge from the error event below still lands.
  }
  try {
    const dur = Math.round(detail.durationMs);
    const msg =
      detail.reason === "error"
        ? `payment failed (${detail.message ?? "gateway error"})`
        : `slow payment ${dur} ms` +
          (detail.country ? ` country=${detail.country}` : "") +
          (detail.scheme ? ` scheme=${detail.scheme}` : "");
    // SplunkRum.reportError reports a handled error as a first-class RUM error
    // event (counts in the RUM Errors / Issues column). NB: the public API on
    // @splunk/otel-web v2 is `reportError`, NOT `error` (the latter silently
    // no-ops). The active session globals (customer.country / customer.tier /
    // customer.location from setRumPersona, plus payment.degraded above) ride
    // on the error span, so it's filterable by location/tier without extra
    // args. A named Error gives the Issues column a readable label.
    const err = new Error(msg);
    err.name = detail.reason === "error" ? "PaymentError" : "PaymentDegraded";
    const sdk = SplunkRum as unknown as {
      reportError?: (e: string | Error) => unknown;
    };
    if (typeof sdk.reportError === "function") {
      sdk.reportError(err);
    }
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn("[rum] reportPaymentDegraded failed", err);
  }
}

// Allowed attribute primitives for RUM page actions. Splunk's resource module
// stringifies these on its own, so we only accept the safe scalar set up front
// to keep span shape consistent across calls.
type PageActionAttrs = Record<string, string | number | boolean>;

// ---- presenter HUD plumbing -------------------------------------------------
// recordPageAction creates a span; the presenter HUD wants to display the
// trace id from the *most recent* such span (so the operator can click
// straight into the matching APM trace without grepping logs). We expose
// the latest trace id via a tiny pub/sub store so React components can
// subscribe without coupling to RUM internals.
//
// This is intentionally local to rum.ts so non-presenter code paths
// continue to depend only on SplunkRum + Persona. The HUD module imports
// the subscribe/get helpers; nothing else does.

export interface LastTrace {
  traceId: string;
  spanId: string;
  name: string;
  timestamp: number; // epoch ms
}

let lastTrace: LastTrace | null = null;
const lastTraceListeners = new Set<(t: LastTrace | null) => void>();

function publishLastTrace(t: LastTrace | null) {
  lastTrace = t;
  // Notify a copy of the set to avoid mutation-during-iteration issues
  // when a listener unsubscribes itself in response to the update.
  for (const fn of Array.from(lastTraceListeners)) {
    try {
      fn(t);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn("[rum] presenter listener threw", err);
    }
  }
}

export function getLastTrace(): LastTrace | null {
  return lastTrace;
}

export function subscribeLastTrace(fn: (t: LastTrace | null) => void): () => void {
  lastTraceListeners.add(fn);
  return () => {
    lastTraceListeners.delete(fn);
  };
}

// Record a Splunk RUM "page action" span - a user-meaningful event surfaced
// in the session timeline (e.g. "Send payment"). The auto-instrumented click
// span covers raw DOM interactions but its name is element-derived ("click
// HTMLButtonElement"), which buries the demo storyline. Calling this helper
// from a submit handler emits a discrete span with a stable name so the
// "browser session -> APM trace" pivot is one click for the audience.
//
// Every span emitted via this helper is stamped with `action.name = <name>`
// so the operation name is also queryable as a regular tag. That tag is
// promoted to a Troubleshooting MetricSet (see scripts/lib/metricsets.json)
// so RUM Tag Spotlight can group by user action — Splunk's default span
// schema indexes operation name only via the special "Operation" pivot,
// not via the generic Breakdown/Filter dropdowns we want for the demo.
//
// SplunkRum.provider is typed as SplunkWebTracerProvider in the SDK; we use
// it rather than @opentelemetry/api to avoid pulling another package into the
// bundle. Falls back to a no-op when RUM is not ready or the provider hasn't
// been wired yet (e.g. token missing in dev).
export function recordPageAction(
  name: string,
  attributes: PageActionAttrs = {},
): void {
  if (!rumReady) return;
  try {
    const tracer = SplunkRum.provider?.getTracer("natwest-payments-web");
    if (!tracer) return;
    const span = tracer.startSpan(name);
    // Stamp the operation name as a queryable tag on every span; explicit
    // attrs win over the auto-stamp so a caller can override the name in
    // the (rare) case where the span name and the analytic dimension
    // need to diverge.
    span.setAttribute("action.name", name);
    for (const [key, value] of Object.entries(attributes)) {
      span.setAttribute(key, value);
    }
    // Grab the span context *before* end() — the SDK is free to recycle
    // span objects after end(), and trace/span IDs are stable on the
    // SpanContext so grabbing them here is safe + cheap.
    const ctx = span.spanContext();
    span.end();
    if (ctx && ctx.traceId && ctx.spanId) {
      publishLastTrace({
        traceId: ctx.traceId,
        spanId: ctx.spanId,
        name,
        timestamp: Date.now(),
      });
    }
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn("[rum] recordPageAction failed", err);
  }
}

// ---- network context (Network Information API) -----------------------------
// Capture the browser's view of the network it's running on (effective type
// 4g/3g/2g/slow-2g, downlink Mbps, RTT ms, save-data flag) and:
//   1. Stamp it onto every subsequent RUM span as a session global, so the
//      Madrid latency story can split p95 by network.effective_type without
//      requiring callers to read navigator.connection on every action.
//   2. Emit a one-shot `network.context` page action so the same dimension
//      shows up as a discrete event in the session timeline (and feeds
//      action.name -> network.context in Tag Spotlight).
//
// The Network Information API is non-standard but available on Chromium and
// most mobile browsers. On Safari / Firefox the `navigator.connection` field
// is undefined and this function silently no-ops — the RUM session still
// works, it just won't carry the network dims for those visitors.
//
// Re-runs on every `change` event from the connection object so a wifi -> 3g
// transition mid-session refreshes the global attributes (presenters love
// being able to flip the laptop to a hotspot mid-demo and watch the metric
// flip in real time).

interface NavigatorConnectionLike {
  effectiveType?: string;
  downlink?: number;
  rtt?: number;
  saveData?: boolean;
  addEventListener?: (event: string, handler: () => void) => void;
}

function getConnection(): NavigatorConnectionLike | null {
  if (typeof navigator === "undefined") return null;
  // The web standards committee uses three different field names for the
  // same API across browsers. Probe all three rather than guess at the
  // current vendor.
  const nav = navigator as unknown as Record<string, unknown>;
  const conn =
    (nav.connection as NavigatorConnectionLike | undefined)
    ?? (nav.mozConnection as NavigatorConnectionLike | undefined)
    ?? (nav.webkitConnection as NavigatorConnectionLike | undefined);
  return conn ?? null;
}

function snapshotNetworkAttrs(
  conn: NavigatorConnectionLike,
): PageActionAttrs {
  const out: PageActionAttrs = {};
  if (typeof conn.effectiveType === "string" && conn.effectiveType) {
    out["network.effective_type"] = conn.effectiveType;
  }
  if (typeof conn.downlink === "number" && Number.isFinite(conn.downlink)) {
    out["network.downlink_mbps"] = conn.downlink;
  }
  if (typeof conn.rtt === "number" && Number.isFinite(conn.rtt)) {
    out["network.rtt_ms"] = conn.rtt;
  }
  if (typeof conn.saveData === "boolean") {
    out["network.save_data"] = conn.saveData;
  }
  return out;
}

// Best-effort read of the active persona from localStorage. Returns null
// if no persona is selected yet (first page load before PersonaProvider
// mounts) or if the storage entry is malformed. Used purely to enrich
// the network audit beacon - no security decision relies on it.
function readActivePersona(): Persona | null {
  try {
    if (typeof window === "undefined") return null;
    const stored = window.localStorage.getItem(PERSONA_STORAGE_KEY);
    return findPersona(stored) ?? null;
  } catch {
    return null;
  }
}

// Pull the current Splunk RUM session id so the audit beacon can be
// joined back to the matching browser session in Splunk Observability.
// SplunkRum.getSessionId() is the documented public API; we wrap it in
// try/catch because some SDK versions throw before init completes.
function rumSessionId(): string | null {
  try {
    const fn = (SplunkRum as unknown as { getSessionId?: () => string }).getSessionId;
    if (typeof fn === "function") {
      const id = fn.call(SplunkRum);
      if (typeof id === "string" && id.length > 0) return id;
    }
  } catch {
    // SDK not ready or unsupported - beacon goes out without session id.
  }
  return null;
}

export function initNetworkContext(config?: AppConfig): void {
  if (!rumReady) return;
  const conn = getConnection();
  if (!conn) return;

  // Track the last effective_type we saw so the audit beacon can carry a
  // from->to delta. The first call fires source="session_start" with no
  // from-state; subsequent change events fire source="change" with the
  // previous value, which is exactly what the ITSI correlation search
  // `[NatWest demo] SPA network connection changed` filters on.
  let lastEffectiveType: string | null = null;
  let beaconedAtLeastOnce = false;

  const apply = () => {
    const attrs = snapshotNetworkAttrs(conn);
    if (Object.keys(attrs).length === 0) return;
    try {
      // Cast each value to a string|number for setGlobalAttributes - the
      // Splunk RUM type uses Attributes which doesn't accept booleans on
      // every minor version. Bool save-data becomes "true"/"false" in
      // Tag Spotlight, which is exactly the dimension presenters want.
      const globals: Record<string, string | number> = {};
      for (const [key, value] of Object.entries(attrs)) {
        globals[key] = typeof value === "boolean" ? String(value) : value;
      }
      SplunkRum.setGlobalAttributes(globals);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn("[rum] initNetworkContext: setGlobalAttributes failed", err);
    }
    recordPageAction("network.context", attrs);

    // Bridge the same signal to Splunk Enterprise (nwpay_audit) so the
    // ITSI correlation search can fire on connection flips. Skip if we
    // don't have a config (back-compat for callers that don't pass one)
    // or the gateway URL is empty (dev mode without a backend).
    if (!config || !config.gatewayUrl) return;
    const effectiveType =
      typeof attrs["network.effective_type"] === "string"
        ? (attrs["network.effective_type"] as string)
        : "unknown";
    const persona = readActivePersona();
    const previous = lastEffectiveType;
    const isFirstBeacon = !beaconedAtLeastOnce;
    // Skip "no-op change" events: connection.change can fire on downlink/RTT
    // jitter even when effective_type is stable. The ITSI search keys on
    // effective_type transitions so beaconing the no-op events would just
    // pad the audit volume without adding signal.
    if (!isFirstBeacon && previous === effectiveType) return;
    lastEffectiveType = effectiveType;
    beaconedAtLeastOnce = true;
    void emitNetworkBeacon(config, {
      session_id: rumSessionId(),
      customer_id: persona?.id ?? null,
      customer_tier: persona?.tier ?? null,
      effective_type: effectiveType,
      previous_effective_type: isFirstBeacon ? null : previous,
      downlink_mbps:
        typeof attrs["network.downlink_mbps"] === "number"
          ? (attrs["network.downlink_mbps"] as number)
          : null,
      rtt_ms:
        typeof attrs["network.rtt_ms"] === "number"
          ? (attrs["network.rtt_ms"] as number)
          : null,
      save_data: !!attrs["network.save_data"],
      source: isFirstBeacon ? "session_start" : "change",
    });
  };

  apply();
  if (typeof conn.addEventListener === "function") {
    try {
      conn.addEventListener("change", apply);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn("[rum] initNetworkContext: change listener failed", err);
    }
  }
}
