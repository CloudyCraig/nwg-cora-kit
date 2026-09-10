// Session driver — opens one browser context, seeds auth + persona,
// drives the SPA through /send, and closes.
//
// Two modes:
//   healthy  → single click on Submit → wait for the success card OR the
//              "payment.completed" RUM span. Under-threshold latency
//              (<1200ms) means the SPA does NOT fire payment.degraded, so
//              the session records a clean success.
//   chaos    → rage-click Submit 6–8 times fast (100–200 ms apart) to trip
//              Splunk RUM's built-in frustrationSignals.rageClick detector.
//              Let the natural chaos-degraded response arrive; if it's slow
//              (~2 s under AML chaos) the SPA fires reportPaymentDegraded()
//              from rum.ts, which stamps payment.degraded=true and posts a
//              first-class RUM error event. We do NOT synthesise any error
//              ourselves — the SPA's existing signal is authoritative.
//
// No credentials are sent. The SPA's demo auth (AuthContext.tsx) reads
// sessionStorage `nw-payments-auth = {"username":"admin"}` on mount; we
// seed that BEFORE the first navigation via context.addInitScript so
// the RequireAuth guard on /send lets us straight through — the same
// technique Craig used successfully on 2026-06-30 (project memory ref).
//
// This deliberately never types the SPA password because that plaintext
// lives outside our reach (see the task brief: "If the SPA password
// lives in a secret you can't access, STOP and report — don't hardcode
// credentials"). Skipping the login form still emits page_view +
// persona-tagged RUM spans; the ONLY thing missing vs a "real" login
// flow is the auth.login.success event, which the traffic-generator's
// AUTH_BEACON already produces continuously on its own.

import { chromium } from "playwright";

import { config, log } from "./config.js";

// Attribute names for the manual override branch (only used when
// a location override is set AND the SPA exposes SplunkRum globally).
// The keys match rum.ts::setRumPersona so downstream dashboards don't
// need any changes.
const RUM_ATTR_LOCATION = "customer.location";
const RUM_ATTR_COUNTRY = "customer.country";

let browserPromise = null;

// Lazy-init a shared Chromium instance. Contexts are cheap to spin up;
// launching Chromium is not. We keep one browser alive for the lifetime
// of the pod and mint a fresh context per session so localStorage /
// sessionStorage / RUM session ids don't bleed across cities.
export async function getBrowser() {
  if (!browserPromise) {
    browserPromise = chromium.launch({
      headless: true,
      // --no-sandbox is required because the container runs as a non-root
      // user without CAP_SYS_ADMIN; chromium's default zygote sandbox
      // needs one or the other. This is a headless demo bot, not a
      // security boundary, so this is fine.
      args: [
        "--no-sandbox",
        "--disable-dev-shm-usage",
        "--disable-gpu",
      ],
    });
  }
  return browserPromise;
}

export async function closeBrowser() {
  if (!browserPromise) return;
  try {
    const b = await browserPromise;
    await b.close();
  } catch (err) {
    log("warn", "browser_close_failed", {
      error: err instanceof Error ? err.message : String(err),
    });
  } finally {
    browserPromise = null;
  }
}

// Build the addInitScript payload for a session. Runs in the page BEFORE
// any SPA script executes.
//   - localStorage.natwest-demo-persona → persona.id
//   - sessionStorage.nw-payments-auth   → {"username":"admin"}
//
// If the caller passed a location override, we also register a
// MutationObserver-free hook that runs on `load` and best-effort calls
// window.SplunkRum.setGlobalAttributes({...}) if the SPA has attached
// the SDK to window (it doesn't today, but this is future-proof and
// costs nothing if it fails).
function buildInitScript(city) {
  const args = {
    personaId: city.personaId,
    locationOverride: city.locationOverride || null,
    countryOverride: city.countryOverride || null,
  };
  return function initScript(a) {
    try {
      // sessionStorage marker the SPA's AuthContext.tsx picks up on mount
      // → RequireAuth accepts the session, no /login bounce.
      sessionStorage.setItem(
        "nw-payments-auth",
        JSON.stringify({ username: "admin" }),
      );
    } catch (_e) { /* private mode / disabled — SPA will bounce to /login */ }
    try {
      localStorage.setItem("natwest-demo-persona", a.personaId);
    } catch (_e) { /* ditto */ }
    if (a.locationOverride || a.countryOverride) {
      // Best-effort: if the SPA ever exposes SplunkRum on window,
      // stamp the overrides after init so customer.location shows the
      // right city even for personas that don't carry a location block
      // (Margaret / London today). Silent no-op otherwise.
      const applyOverrides = () => {
        try {
          const sdk = window.SplunkRum;
          if (!sdk || typeof sdk.setGlobalAttributes !== "function") return false;
          const attrs = {};
          if (a.locationOverride) attrs["customer.location"] = a.locationOverride;
          if (a.countryOverride) attrs["customer.country"] = a.countryOverride;
          sdk.setGlobalAttributes(attrs);
          return true;
        } catch (_e) { return false; }
      };
      // Try a few times as the SDK inits async.
      let tries = 0;
      const t = setInterval(() => {
        tries += 1;
        if (applyOverrides() || tries >= 20) clearInterval(t);
      }, 200);
    }
  }.toString().replace("(a)", `(${JSON.stringify(args)})`);
}

// Compact wrapper — Playwright's addInitScript takes either a raw fn
// with args OR a string. We use the string form so the arg is baked in
// at the top of the script and the fn is self-executing.
export function initScriptSource(cityKey, city) {
  const cityJson = JSON.stringify({
    city: cityKey,
    personaId: city.personaId,
    locationOverride: city.locationOverride || null,
    countryOverride: city.countryOverride || null,
  });
  return `(function(){
  var a = ${cityJson};
  try { sessionStorage.setItem("nw-payments-auth", JSON.stringify({username:"admin"})); } catch(e){}
  try { localStorage.setItem("natwest-demo-persona", a.personaId); } catch(e){}
  // Stamp user.location (+ customer.location where missing) into every
  // RUM beacon before it leaves the browser. The SPA bundles
  // @splunk/otel-web privately (no window.SplunkRum), so rewriting the
  // exporter's HTTP bodies is the only injection point that always works.
  // Equivalent to setGlobalAttributes({"user.location": city}) on every span.
  // Match ONLY the span-ingest endpoint (/v1/rum or /v1/rum?auth=...).
  // A bare indexOf("/v1/rum") also matches /v1/rumreplay — the session
  // replay uploader — which must never be rewritten. Plain string ops
  // (NOT a regex literal): this code lives inside a template literal,
  // where backslash escapes get processed and a /\/.../ regex silently
  // turns into a // line comment in the generated page script.
  var isRum = function(u){
    return typeof u === "string"
      && u.indexOf("/v1/rum") !== -1
      && u.indexOf("/v1/rumreplay") === -1;
  };
  var stamp = function(body){
    try {
      var spans = JSON.parse(body);
      if (!Array.isArray(spans)) return body;
      for (var i = 0; i < spans.length; i++) {
        var t = spans[i].tags || (spans[i].tags = {});
        t["user.location"] = a.city;
        if (!t["customer.location"]) t["customer.location"] = a.city;
      }
      return JSON.stringify(spans);
    } catch(e) { return body; }
  };
  try {
    var XO = XMLHttpRequest.prototype.open, XS = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function(m, u){ this.__rumUrl = u; return XO.apply(this, arguments); };
    XMLHttpRequest.prototype.send = function(b){
      if (isRum(this.__rumUrl) && typeof b === "string") b = stamp(b);
      return XS.call(this, b);
    };
  } catch(e){}
  try {
    if (navigator.sendBeacon) {
      var SB = navigator.sendBeacon.bind(navigator);
      navigator.sendBeacon = function(u, b){
        if (isRum(u) && typeof b === "string") b = stamp(b);
        return SB(u, b);
      };
    }
  } catch(e){}
  try {
    var F = window.fetch;
    if (F) {
      window.fetch = function(u, o){
        try {
          var url = typeof u === "string" ? u : (u && u.url);
          if (isRum(url) && o && typeof o.body === "string") o = Object.assign({}, o, { body: stamp(o.body) });
        } catch(e){}
        return F.apply(this, arguments);
      };
    }
  } catch(e){}
  if (a.locationOverride || a.countryOverride) {
    var tries = 0;
    var t = setInterval(function(){
      tries += 1;
      try {
        var sdk = window.SplunkRum;
        if (sdk && typeof sdk.setGlobalAttributes === "function") {
          var attrs = {};
          if (a.locationOverride) attrs["${RUM_ATTR_LOCATION}"] = a.locationOverride;
          if (a.countryOverride) attrs["${RUM_ATTR_COUNTRY}"] = a.countryOverride;
          sdk.setGlobalAttributes(attrs);
          clearInterval(t);
          return;
        }
      } catch(e){}
      if (tries >= 20) clearInterval(t);
    }, 200);
  }
})();`;
}

// Run one full browser session. `mode` is "healthy" or "chaos".
// Returns { ok, mode, durationMs, cityKey, error? } — never throws.
export async function runSession({ cityKey, city, mode }) {
  const startedAt = Date.now();
  const budgetMs = config.sessionBudgetSeconds * 1000;
  let context = null;
  let page = null;
  try {
    const browser = await getBrowser();
    context = await browser.newContext({
      viewport: { width: 1280, height: 800 },
      // Pretend to be a plausible desktop. If your DXA saved searches
      // filter on user-agent, tune this string.
      // Realistic Chrome UA with the simulator token at the END. The
      // previous "HeadlessChrome/1.51" string made @splunk/otel-web's
      // session recorder parse the browser as Chrome v1 and take a broken
      // legacy path (TypeError: A.entries is not iterable on every DOM
      // mutation) — killing session replay and spraying JS-error events
      // into every session. Verified empirically 2026-07-13.
      userAgent:
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) " +
        "Chrome/134.0.0.0 Safari/537.36 rum-user-simulator/0.1",
      locale: "en-GB",
      // Emit deterministic viewport-related RUM dims regardless of the
      // pod's screen configuration.
      deviceScaleFactor: 1,
    });
    await context.addInitScript(initScriptSource(cityKey, city));

    page = await context.newPage();
    page.setDefaultTimeout(budgetMs);
    page.setDefaultNavigationTimeout(budgetMs);

    // Land on /send directly. The RequireAuth guard sees the sessionStorage
    // marker (seeded in initScript) and lets us through, so no login click
    // is required.
    const target = `${config.spaUrl.replace(/\/+$/, "")}/send`;
    await page.goto(target, { waitUntil: "domcontentloaded" });

    // Wait for the SPA form to render — the primary Submit button (
    // "Review and send" / "Sending…" / "Send N payments"). The form's
    // primary class is `.primary` (see SendMoney.tsx) but there is a
    // second `.primary` inside the SuccessCard, so we scope by type +
    // form context to avoid the false positive.
    const submit = page.locator('form.send-form button[type="submit"].primary');
    await submit.waitFor({ state: "visible" });

    if (mode === "chaos") {
      // Rage-click loop — trips Splunk RUM's built-in frustrationSignals
      // rage-click detector (rum.ts turns rageClick:true on for the SDK).
      //
      // Gotcha: React sets the Submit button `disabled={submitting}` the
      // moment the first click fires. Chromium suppresses click events on
      // disabled buttons entirely — so a naive `page.click()` × 7 emits
      // only ONE click event and Splunk's detector never trips. We
      // side-step by:
      //   1. Firing click #1 through Playwright normally (real submit).
      //   2. Dispatching clicks #2–N via page.evaluate() as raw MouseEvent
      //      instances on the button element with bubbles:true, so they
      //      reach the document-level listener the RUM SDK hooks for
      //      rage-click detection — even after `disabled` is applied.
      const btnHandle = await submit.elementHandle();
      await submit.click({ noWaitAfter: true }).catch(() => {});
      if (btnHandle) {
        await page.evaluate(
          async ({ el, count, gap }) => {
            // Clicks 2-N target the button's PARENT, not the button:
            // (a) that's what the browser does for a real user clicking a
            //     disabled control (disabled elements aren't event targets),
            // (b) the SDK's rage-click detector drops disabled targets, so
            //     bursts aimed at the button itself never emit the
            //     frustration_type=rage span DXA pivots on. Verified
            //     empirically against @splunk/otel-web 2.5.1 (>=4 clicks on
            //     the same non-disabled node within 1s => rage span).
            const target = el.parentElement || el;
            for (let i = 0; i < count; i++) {
              try {
                const rect = el.getBoundingClientRect();
                const ev = new MouseEvent("click", {
                  bubbles: true,
                  cancelable: true,
                  view: window,
                  clientX: rect.left + rect.width / 2,
                  clientY: rect.top + rect.height / 2,
                  button: 0,
                });
                target.dispatchEvent(ev);
              } catch (_e) { /* ignore per-click errors */ }
              await new Promise((r) => setTimeout(r, gap));
            }
          },
          {
            el: btnHandle,
            count: Math.max(0, config.rageClickCount - 1),
            gap: config.rageClickGapMs,
          },
        );
      }
    } else {
      await submit.click();
    }

    // Let the natural response arrive (success card, error line, OR the
    // chaos-degraded slow-200 which the SPA flags with payment.degraded).
    // We don't strictly need to observe the outcome — RUM has already
    // captured it — but waiting for the SendMoney submit handler to
    // resolve avoids racing SIGTERM-on-close against in-flight spans.
    //
    // Success renders the `.success-card` component; batch/error render
    // an inline `.status-line`. Either resolution => submit handler done.
    await Promise.race([
      page.locator(".success-card").waitFor({ state: "visible" })
        .catch(() => null),
      page.locator(".status-line").waitFor({ state: "visible" })
        .catch(() => null),
      page.waitForTimeout(mode === "chaos" ? 8000 : 4000),
    ]);

    // Small settle window so the "payment.completed" RUM span has time
    // to flush before we tear down. The Splunk RUM SDK batches on a
    // ~5s cadence but also flushes on visibility change (page.close()
    // triggers pagehide, which is exactly this).
    await page.waitForTimeout(500);

    return {
      ok: true,
      mode,
      cityKey,
      durationMs: Date.now() - startedAt,
    };
  } catch (err) {
    return {
      ok: false,
      mode,
      cityKey,
      durationMs: Date.now() - startedAt,
      error: err instanceof Error ? err.message : String(err),
    };
  } finally {
    if (page) { try { await page.close(); } catch (_e) { /* ignore */ } }
    if (context) { try { await context.close(); } catch (_e) { /* ignore */ } }
  }
}
