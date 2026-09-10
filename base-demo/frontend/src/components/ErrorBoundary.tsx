// ErrorBoundary - catches uncaught render-time errors anywhere in the
// SPA tree and:
//
//   1. Emits a `error.boundary` RUM page action so the failure shows up
//      in Tag Spotlight as a discrete event instead of a silent
//      console error. The action carries the component stack head and
//      the error name + message (no stack trace - those leak file
//      paths from the Vite-built bundle which are awkward to redact in
//      production telemetry).
//
//   2. Renders a friendly fallback card so the audience sees a graceful
//      "something went wrong" surface rather than a blank screen mid-
//      demo. The card includes a "Reload" button so the operator can
//      recover without dropping the browser session (which would lose
//      the persona, the chaos token, and the RUM trace context).
//
// The boundary intentionally only catches *render* errors - async work
// inside event handlers (e.g. fetch failures from chaos.ts) bypass
// React's error boundary mechanism. Those code paths emit their own
// dedicated RUM events (payment.completed { outcome: "error" } etc.)
// from their own try/catch blocks.

import { Component, ErrorInfo, ReactNode } from "react";

import { recordPageAction } from "../rum";

interface Props {
  children: ReactNode;
}

interface State {
  hasError: boolean;
  errorMessage: string | null;
}

export default class ErrorBoundary extends Component<Props, State> {
  state: State = { hasError: false, errorMessage: null };

  static getDerivedStateFromError(error: unknown): State {
    const message =
      error instanceof Error
        ? error.message
        : typeof error === "string"
          ? error
          : "Unexpected SPA error";
    return { hasError: true, errorMessage: message };
  }

  componentDidCatch(error: unknown, info: ErrorInfo): void {
    const errName = error instanceof Error ? error.name : "UnknownError";
    const errMsg = error instanceof Error ? error.message : String(error);
    // info.componentStack is multi-line; take the first non-empty line so
    // RUM Tag Spotlight stays scannable. We deliberately don't ship the
    // full stack to avoid leaking bundle paths into RUM payloads.
    const firstStackLine =
      (info.componentStack ?? "")
        .split("\n")
        .map((s) => s.trim())
        .find((s) => s.length > 0) ?? "";
    recordPageAction("error.boundary", {
      "error.name": errName,
      "error.message": errMsg,
      "error.component_stack_head": firstStackLine,
    });
  }

  handleReload = (): void => {
    // Best-effort: a hard reload keeps the URL (so the operator lands
    // back on /send if that's where the error happened) but resets all
    // in-memory React state.
    if (typeof window !== "undefined") {
      window.location.reload();
    }
  };

  render(): ReactNode {
    if (!this.state.hasError) {
      return this.props.children;
    }
    return (
      <section className="card status-page" role="alert" aria-live="assertive">
        <div className="card__header">
          <h2>Something went wrong</h2>
          <span className="card__sub">
            The SPA hit an unexpected error and stopped rendering this view. The
            failure has been reported to Splunk RUM as
            <code style={{ marginLeft: 6 }}>error.boundary</code>.
          </span>
        </div>
        <div className="status-detail status-detail--error">
          <h3>Demo SPA error</h3>
          <p>
            <strong>Detail:</strong>{" "}
            {this.state.errorMessage ?? "no further detail available"}
          </p>
          <p className="status-detail__hint">
            Click <em>Reload</em> to start fresh. Your persona and chaos token
            survive the reload. If this keeps happening, capture the trace via
            Splunk RUM and re-bootstrap the SPA pod.
          </p>
          <div style={{ marginTop: 16 }}>
            <button type="button" className="primary" onClick={this.handleReload}>
              Reload
            </button>
          </div>
        </div>
      </section>
    );
  }
}
