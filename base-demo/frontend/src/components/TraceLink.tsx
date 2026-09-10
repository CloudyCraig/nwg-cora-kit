// TraceLink — renders a Splunk RUM/APM trace id as a compact, copyable
// chip with a one-click external link to the matching APM trace in
// Splunk Observability Cloud.
//
// The Send Money confirmation card, the Payment Status page and the
// Recent Payments table all surface trace ids; centralising the chip
// here means the audience sees the same affordance every time the demo
// pivots from a session into APM.
//
// The component intentionally does not depend on @splunk/otel-web — the
// trace id is already in hand by the time we render. We just need the
// realm (from AppConfig.rumRealm) to build the deep link.

import { useState } from "react";

import { apmTraceUrl, shortTrace } from "../format";

interface Props {
  traceId: string | null | undefined;
  realm: string | undefined;
  // When true (default) the chip shows a short "abc123…" preview. Pass
  // false on the success card to render the full trace id under the
  // amount — the layout there has enough room for it.
  short?: boolean;
  // Extra CSS class for layout tweaks.
  className?: string;
}

export default function TraceLink({ traceId, realm, short = true, className }: Props) {
  const [copied, setCopied] = useState(false);

  if (!traceId) {
    return <span className="trace-link trace-link--empty">—</span>;
  }

  const text = short ? shortTrace(traceId) : traceId;
  const apm = apmTraceUrl(realm, traceId);

  async function copyTraceId() {
    try {
      await navigator.clipboard.writeText(traceId as string);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1200);
    } catch {
      // Clipboard API may be unavailable (insecure context, locked-down
      // browser). Silently swallow — the link is still usable.
    }
  }

  return (
    <span className={`trace-link${className ? " " + className : ""}`}>
      <button
        type="button"
        className="trace-link__id"
        onClick={copyTraceId}
        title={copied ? "Copied" : `Copy ${traceId}`}
        aria-label={copied ? "Trace id copied" : `Copy trace id ${traceId}`}
      >
        <span className="trace-link__id-text">{text}</span>
        <span className="trace-link__copy" aria-hidden="true">
          {copied ? "\u2713" : "\u2398"}
        </span>
      </button>
      <a
        className="trace-link__apm"
        href={apm}
        target="_blank"
        rel="noopener noreferrer"
        title="Open trace in Splunk APM"
        aria-label="Open trace in Splunk APM"
      >
        APM
        <span aria-hidden="true" className="trace-link__ext">{"\u2197"}</span>
      </a>
    </span>
  );
}
