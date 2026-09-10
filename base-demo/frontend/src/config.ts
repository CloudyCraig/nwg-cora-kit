// Runtime configuration shape. The actual values are populated by
// /config.js, which nginx serves from a ConfigMap-rendered template at
// container boot. Falls back to safe demo defaults when the script is
// missing (e.g. local `vite dev`).

// Auth config injected via /config.js. The plaintext password is never
// shipped to the browser - only the SHA-256 hash. The login form computes
// SHA-256 of the user's input client-side and compares (constant-time) to
// `passwordSha256`. This is a demo gate, not real authentication; for any
// production system replace with a server-issued session cookie + proper
// authn flow. See [helm/natwest-payments/templates/web-frontend.yaml] for
// how AUTH_PASSWORD_SHA256 is plumbed from a chart-managed Secret.
export interface AuthConfig {
  enabled: boolean;
  username: string;
  passwordSha256: string;
}

// App channel ("web" vs "mobile"). The same SPA bundle serves both
// channels; the variant is selected at boot from a sticky URL query
// parameter (?app=mobile) and persisted in sessionStorage so subsequent
// navigations within the SPA keep the mobile framing.
//
// "mobile" mode does two things:
//   * RUM `applicationName` is overridden to natwest-payments-mobile
//     (and a `channel=mobile` global attribute is set), so Splunk
//     Observability draws a separate RUM application tile and Tag
//     Spotlight breaks down sessions by channel.
//   * The shell wraps the React tree in a phone-shaped frame
//     (.mobile-frame in styles.css) so the demo audience sees an
//     unmistakably mobile-shaped surface even though it's a SPA.
export type AppChannel = "web" | "mobile";

const CHANNEL_STORAGE_KEY = "natwest.demo.channel";
const PRESENTER_STORAGE_KEY = "natwest.demo.presenter";
const OPS_STORAGE_KEY = "natwest.demo.ops";

function detectChannel(): AppChannel {
  // Allow-list against a closed enum so a typo (?app=foo) silently
  // resolves back to web rather than letting arbitrary strings flow
  // into RUM applicationName.
  try {
    const params = new URLSearchParams(window.location.search);
    const param = params.get("app");
    if (param === "mobile" || param === "web") {
      window.sessionStorage.setItem(CHANNEL_STORAGE_KEY, param);
      return param;
    }
    const stored = window.sessionStorage.getItem(CHANNEL_STORAGE_KEY);
    if (stored === "mobile" || stored === "web") {
      return stored;
    }
  } catch {
    // sessionStorage / URLSearchParams unavailable (very old WebView).
    // Fall through to the default.
  }
  return "web";
}

// `?presenter=1` enables the on-screen HUD (PresenterHUD.tsx). Sticky
// across same-tab navigations via sessionStorage so the operator doesn't
// have to keep re-appending the query string. `?presenter=0` disables.
//
// The HUD never collects or sends data — it's read-only UI plumbing.
// Treating presenter mode as a closed boolean (rather than free text)
// keeps the same allow-list discipline as detectChannel above.
export function detectPresenterMode(): boolean {
  try {
    const params = new URLSearchParams(window.location.search);
    const param = params.get("presenter");
    if (param === "1" || param === "true") {
      window.sessionStorage.setItem(PRESENTER_STORAGE_KEY, "1");
      return true;
    }
    if (param === "0" || param === "false") {
      window.sessionStorage.removeItem(PRESENTER_STORAGE_KEY);
      return false;
    }
    return window.sessionStorage.getItem(PRESENTER_STORAGE_KEY) === "1";
  } catch {
    return false;
  }
}

// `?ops=1` flips the SPA into "ops mode": the Chaos Dashboard route at
// /ops becomes reachable, the navigation grows an "Ops" link, and the
// PresenterHUD polls the chaos-controller for armed-scenario counts.
// Sticky in sessionStorage exactly like the presenter / channel modes;
// `?ops=0` disables. Defaults closed, so end users browsing the SPA
// never see the dashboard.
//
// This is UI plumbing only. The actual safety gate is the X-Chaos-Token
// header on every POST to /chaos/api/* (auth.py in chaos-controller).
// Without that token an opsMode=true SPA can read the catalog (status
// only) but cannot mutate anything.
export function detectOpsMode(): boolean {
  try {
    const params = new URLSearchParams(window.location.search);
    const param = params.get("ops");
    if (param === "1" || param === "true") {
      window.sessionStorage.setItem(OPS_STORAGE_KEY, "1");
      return true;
    }
    if (param === "0" || param === "false") {
      window.sessionStorage.removeItem(OPS_STORAGE_KEY);
      return false;
    }
    return window.sessionStorage.getItem(OPS_STORAGE_KEY) === "1";
  } catch {
    return false;
  }
}

export interface AppConfig {
  rumRealm: string;
  rumAccessToken: string;
  applicationName: string;
  deploymentEnvironment: string;
  gatewayUrl: string;
  channel: AppChannel;
  // True when ?presenter=1 was on the URL (or sticky in sessionStorage).
  // Activates the on-screen HUD; never sent to the server.
  presenterMode: boolean;
  // True when ?ops=1 was on the URL (or sticky in sessionStorage).
  // Exposes the /ops Chaos Dashboard route + nav link.
  opsMode: boolean;
  // Presenter token used by frontend/src/chaos.ts as the X-Chaos-Token
  // header. Injected via /config.js at boot (chart-managed Secret), so
  // the plaintext never enters the source tree. Empty means the SPA
  // cannot drive chaos actions even if opsMode is on - the catalog
  // endpoint will return 401 without it.
  chaosToken: string;
  // Optional deep-link targets for the top-nav cross-launch buttons.
  // Empty string => link hidden. Operators wire these via the chart
  // (helm/.../values.yaml -> frontend.observabilityUrl / itsiUrl).
  //   * observabilityUrl: typically https://app.<realm>.signalfx.com/
  //     (APM Service Map, Tag Spotlight, RUM dashboards).
  //   * itsiUrl: typically https://<splunk-enterprise-fqdn>:8000/en-US/
  //     app/itsi (Episode Review, Service Analyzer, Glass Tables).
  //   * thousandEyesUrl: typically https://app.thousandeyes.com/ or a
  //     scoped link like .../?aid=<account-group-id>#/views/tests so
  //     the operator lands directly on the demo's synthetic tests.
  // The values are opaque to the SPA -- whatever the operator sets is
  // what the link opens. There is no schema validation, but the
  // entrypoint shell-quotes them so a stray `"` in env can't break the
  // rendered /config.js.
  observabilityUrl: string;
  itsiUrl: string;
  thousandEyesUrl: string;
  auth: AuthConfig;
}

declare global {
  interface Window {
    __APP_CONFIG__?: Partial<
      Omit<AppConfig, "auth" | "channel" | "presenterMode" | "opsMode">
    > & {
      auth?: Partial<AuthConfig>;
    };
  }
}

const defaults: AppConfig = {
  rumRealm: "us0",
  rumAccessToken: "",
  applicationName: "natwest-payments-web",
  deploymentEnvironment: "demo",
  gatewayUrl: "/api",
  channel: "web",
  presenterMode: false,
  opsMode: false,
  chaosToken: "",
  observabilityUrl: "",
  itsiUrl: "",
  thousandEyesUrl: "",
  auth: {
    enabled: false,
    username: "",
    passwordSha256: "",
  },
};

export function loadConfig(): AppConfig {
  const injected = window.__APP_CONFIG__ ?? {};
  const channel = detectChannel();
  const presenterMode = detectPresenterMode();
  const opsMode = detectOpsMode();
  // Override the RUM application name for the mobile channel so
  // Splunk Observability splits the RUM dashboard view into a
  // distinct "natwest-payments-mobile" application. The web bundle
  // and the mobile bundle are otherwise identical.
  const baseAppName = injected.applicationName ?? defaults.applicationName;
  const applicationName =
    channel === "mobile"
      ? baseAppName.replace(/-web$/, "-mobile") || "natwest-payments-mobile"
      : baseAppName;
  return {
    ...defaults,
    ...injected,
    applicationName,
    channel,
    presenterMode,
    opsMode,
    auth: {
      ...defaults.auth,
      ...(injected.auth ?? {}),
    },
  };
}
