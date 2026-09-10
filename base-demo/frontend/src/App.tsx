import { ReactNode, useEffect, useRef } from "react";
import {
  Navigate,
  NavLink,
  Outlet,
  Route,
  Routes,
  useLocation,
} from "react-router-dom";

import { AuthProvider, useAuth } from "./AuthContext";
import ErrorBoundary from "./components/ErrorBoundary";
import NatWestLogo from "./components/NatWestLogo";
import PersonaSwitcher from "./components/PersonaSwitcher";
import PresenterHUD from "./components/PresenterHUD";
import { PersonaProvider } from "./PersonaContext";
import { AppConfig } from "./config";
import Home from "./pages/Home";
import Login from "./pages/Login";
import Ops from "./pages/Ops";
import PaymentStatus from "./pages/PaymentStatus";
import RecentPayments from "./pages/RecentPayments";
import SendMoney from "./pages/SendMoney";
import { recordPageAction } from "./rum";

interface AppProps {
  config: AppConfig;
}

// Wraps any route that requires the user to be signed in. When the user
// isn't authed, redirect to /login and remember where they were trying to
// go (state.from) so we can bounce them back after a successful sign-in.
function RequireAuth({ children }: { children: ReactNode }) {
  const { isAuthed } = useAuth();
  const location = useLocation();
  if (!isAuthed) {
    return (
      <Navigate
        to="/login"
        state={{ from: location.pathname + location.search }}
        replace
      />
    );
  }
  return <>{children}</>;
}

// Emit a `route.transition` RUM page action whenever react-router swaps
// the active route. Each transition carries the previous and next path
// so the funnel pivot in Tag Spotlight (Home -> Send -> Status) lights
// up as a discrete event series. The very first navigation has
// route.from = "" because the document-load span already captures the
// initial URL via the RUM SDK's auto-instrumentation.
function useRouteTransitionTelemetry(): void {
  const location = useLocation();
  const previousRef = useRef<string>("");
  useEffect(() => {
    const next = location.pathname;
    const previous = previousRef.current;
    if (previous === next) return;
    recordPageAction("route.transition", {
      "route.from": previous,
      "route.to": next,
      // The router uses "PUSH" for normal nav, "POP" for back/forward,
      // "REPLACE" for redirect. We don't have the navigation type
      // directly from useLocation, so derive it best-effort: if there
      // was no previous route, this is the initial load.
      "navigation.type": previous === "" ? "initial" : "push",
    });
    previousRef.current = next;
  }, [location.pathname]);
}

// Emit a discrete `cross_launch.clicked` RUM page action and let the
// browser follow the link normally (we don't preventDefault). The event
// carries the target system + the route we left from so the operator-
// usage pivot in Tag Spotlight reads as a clean funnel.
function emitCrossLaunchClick(
  target: "observability" | "itsi" | "thousandeyes",
  routeFrom: string,
): void {
  recordPageAction("cross_launch.clicked", {
    "cross_launch.target": target,
    "route.from": routeFrom,
  });
}

function ProtectedShell({ config }: { config: AppConfig }) {
  const { enabled, username, logout } = useAuth();
  const location = useLocation();
  useRouteTransitionTelemetry();
  return (
    <PersonaProvider>
      <div className="app-shell">
        <header className="app-header">
          <h1 className="app-header__brand">
            <NatWestLogo height={32} />
            <span className="app-header__divider" aria-hidden="true" />
            <span className="app-header__product">Online Banking</span>
          </h1>
          <nav>
            <NavLink to="/" end>
              Home
            </NavLink>
            <NavLink to="/send">Send money</NavLink>
            <NavLink to="/status">Payment status</NavLink>
            <NavLink to="/recent">Recent</NavLink>
            {/*
              Chaos dashboard link. Visible whenever the chaos-controller
              is actually deployed (config.chaosToken is rendered into
              /config.js by helm/.../templates/web-frontend.yaml only when
              chaosController.enabled=true). The real safety gate is the
              X-Chaos-Token header on every POST in chaos.ts; this menu
              entry is just a discoverable affordance for the presenter.
            */}
            {config.chaosToken && (
              <NavLink
                to="/ops"
                className="nav-link--ops"
                title="Chaos dashboard \u2014 mutates the live cluster"
                aria-label="Chaos dashboard (mutates the live cluster)"
              >
                Chaos
              </NavLink>
            )}
            {/*
              Cross-launch links into the two operator surfaces the demo
              relies on. Plain <a target="_blank"> rather than NavLink
              because they leave the SPA. `rel="noopener noreferrer"`
              prevents the opened tab from getting a window.opener handle
              back into the SPA (tabnabbing) and stops the Referer header
              from leaking the SPA URL into Splunk's access logs.
              Visibility is gated on the config URL being a non-empty
              string so the link silently disappears in local `vite dev`
              and on tenants that haven't set the corresponding chart
              value -- avoids shipping a visibly-dead link.
            */}
            {config.observabilityUrl && (
              <a
                className="nav-link--external"
                href={config.observabilityUrl}
                target="_blank"
                rel="noopener noreferrer"
                title="Open Splunk Observability Cloud in a new tab"
                aria-label="Open Splunk Observability Cloud in a new tab"
                onClick={() =>
                  emitCrossLaunchClick("observability", location.pathname)
                }
              >
                Observability
                <span className="nav-link__ext-glyph" aria-hidden="true">
                  {"\u2197"}
                </span>
              </a>
            )}
            {config.itsiUrl && (
              <a
                className="nav-link--external"
                href={config.itsiUrl}
                target="_blank"
                rel="noopener noreferrer"
                title="Open Splunk ITSI in a new tab"
                aria-label="Open Splunk ITSI in a new tab"
                onClick={() => emitCrossLaunchClick("itsi", location.pathname)}
              >
                ITSI
                <span className="nav-link__ext-glyph" aria-hidden="true">
                  {"\u2197"}
                </span>
              </a>
            )}
            {config.thousandEyesUrl && (
              <a
                className="nav-link--external"
                href={config.thousandEyesUrl}
                target="_blank"
                rel="noopener noreferrer"
                title="Open Cisco ThousandEyes in a new tab"
                aria-label="Open Cisco ThousandEyes in a new tab"
                onClick={() =>
                  emitCrossLaunchClick("thousandeyes", location.pathname)
                }
              >
                ThousandEyes
                <span className="nav-link__ext-glyph" aria-hidden="true">
                  {"\u2197"}
                </span>
              </a>
            )}
          </nav>
          <PersonaSwitcher />
          {enabled && username && (
            <div className="user-menu">
              <span className="user-menu__name">{username}</span>
              <button
                type="button"
                className="link-button"
                onClick={logout}
                aria-label="Sign out"
              >
                Sign out
              </button>
            </div>
          )}
        </header>
        <main className="app-main">
          {/*
            Wrap the routed page content in a React error boundary so a
            render-time bug in any page surfaces as a friendly card +
            an `error.boundary` RUM event instead of a blank screen
            mid-demo. Header + nav + persona switcher stay rendered so
            the operator can still navigate / switch persona / sign out.
          */}
          <ErrorBoundary>
            <Outlet />
          </ErrorBoundary>
        </main>
        {config.presenterMode && <PresenterHUD config={config} />}
      </div>
    </PersonaProvider>
  );
}

// Wraps the SPA in a phone-shaped chrome when the channel was selected
// as "mobile" (?app=mobile in the URL). The frame is purely cosmetic:
// the React tree, routes and gateway interactions are identical, but
// the audience sees an unmistakably mobile-shaped surface and Splunk
// Observability draws a separate RUM application + channel=mobile
// dimension on every span (see config.ts::detectChannel,
// rum.ts::initRum globalAttributes).
function MobileFrame({ children }: { children: ReactNode }) {
  return (
    <div className="mobile-stage" data-testid="mobile-stage">
      <div className="mobile-frame" role="presentation">
        <div className="mobile-frame__notch" aria-hidden="true" />
        <div className="mobile-frame__screen">{children}</div>
        <div className="mobile-frame__home" aria-hidden="true" />
      </div>
      <div className="mobile-stage__caption">
        NatWest mobile demo &mdash; <code>app.name=natwest-payments-mobile</code>
      </div>
    </div>
  );
}

export default function App({ config }: AppProps) {
  const tree = (
    <AuthProvider config={config}>
      <Routes>
        <Route path="/login" element={<Login />} />
        <Route
          element={
            <RequireAuth>
              <ProtectedShell config={config} />
            </RequireAuth>
          }
        >
          <Route path="/" element={<Home config={config} />} />
          <Route path="/send" element={<SendMoney config={config} />} />
          <Route path="/status" element={<PaymentStatus config={config} />} />
          <Route path="/recent" element={<RecentPayments config={config} />} />
          {/*
            /ops is reachable whenever the chaos-controller is deployed
            (config.chaosToken non-empty). When the controller isn't
            installed the route falls through to the catch-all -> redirect
            to home. Mutations are still gated server-side by
            X-Chaos-Token in chaos-controller/app/auth.py.
          */}
          {config.chaosToken && (
            <Route path="/ops" element={<Ops config={config} />} />
          )}
        </Route>
        {/* Anything we didn't match - bounce to home so RequireAuth can decide. */}
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </AuthProvider>
  );
  return config.channel === "mobile" ? <MobileFrame>{tree}</MobileFrame> : tree;
}
