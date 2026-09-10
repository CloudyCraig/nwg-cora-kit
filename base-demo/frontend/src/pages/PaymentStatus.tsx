// Payment Status — look up a payment by id and render a clean detail
// card.
//
// Compared to the previous build:
//   * Replaces the raw JSON.stringify(result) blob with a structured
//     detail card (status pill, amount, payee/customer, trace pivot).
//   * Keeps the "Use latest local" convenience button so the audience
//     doesn't have to retype a UUID.
//   * Keeps the GET /api/status/<id> call as the only network side-
//     effect — the gateway produces the Server-Timing header the demo
//     pivots from RUM into APM.

import { FormEvent, useState } from "react";

import { ServerStatusResponse, fetchPaymentStatus } from "../api";
import StatusPill, { statusKindFor } from "../components/StatusPill";
import TraceLink from "../components/TraceLink";
import { AppConfig } from "../config";
import { formatClock, formatMinor, formatRelative } from "../format";
import { loadHistory } from "../history";
import { TIER_COLOURS, Tier, tierLabel } from "../personas";
import { recordPageAction } from "../rum";

interface Props {
  config: AppConfig;
}

// Resolve the rendered status block kind: "ok" if the gateway found a
// matching record, "neutral" for not_found, "error" for a transport
// failure. Used to color the hero strip on the detail card.
function heroKindFor(result: ServerStatusResponse | null, error: string | null) {
  if (error) return "error" as const;
  if (!result) return "idle" as const;
  if (result.status === "not_found") return "neutral" as const;
  return statusKindFor(result.status);
}

export default function PaymentStatus({ config }: Props) {
  const [paymentId, setPaymentId] = useState("");
  const [result, setResult] = useState<ServerStatusResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  async function handleLookup(e: FormEvent) {
    e.preventDefault();
    setResult(null);
    setError(null);

    const id = paymentId.trim();
    if (!id) return;

    setSubmitting(true);
    // Wall-clock the lookup so the RUM event carries client-perceived
    // latency separate from any server-side Server-Timing header. The
    // status endpoint isn't called in a poll loop today (one-shot
    // user lookup), so `lookup.attempts` stays at 1; the field is
    // there so a future polling implementation can populate it
    // without breaking the dimension shape in Tag Spotlight.
    const startedAt = performance.now();
    try {
      const status = await fetchPaymentStatus(config, id);
      const lookupMs = Math.round(performance.now() - startedAt);
      setResult(status);
      // Stamp the terminal-state event. status.final is the server-
      // canonical state ("settled", "rejected", "in_flight",
      // "not_found") - we surface it as a stable dimension so the
      // payment-outcome funnel (initiated -> completed -> terminal)
      // is queryable end to end.
      recordPageAction("payment.status.terminal", {
        "payment.id": status.payment_id ?? id,
        "payment.scheme": status.scheme ?? "",
        "status.final": status.status ?? "unknown",
        "status.outcome":
          status.status === "not_found"
            ? "not_found"
            : status.status === "rejected" || status.status === "failed"
              ? "rejected"
              : "settled",
        "lookup.attempts": 1,
        "lookup.duration_ms": lookupMs,
        "customer.tier": status.customer_tier ?? "",
      });
    } catch (err) {
      const lookupMs = Math.round(performance.now() - startedAt);
      const msg = err instanceof Error ? err.message : String(err);
      setError(msg);
      // Lookup transport / parse failure - emit the same event with a
      // distinct status.outcome="error" so Tag Spotlight breakdown
      // reads cleanly: settled vs rejected vs not_found vs error.
      recordPageAction("payment.status.terminal", {
        "payment.id": id,
        "payment.scheme": "",
        "status.final": "lookup_failed",
        "status.outcome": "error",
        "lookup.attempts": 1,
        "lookup.duration_ms": lookupMs,
        "error.kind": err instanceof TypeError ? "network" : "http_error",
        "error.message": msg,
        "customer.tier": "",
      });
    } finally {
      setSubmitting(false);
    }
  }

  // Convenience: pre-populate the input from the most recent local
  // payment (if any) so the audience doesn't have to retype a UUID.
  function fillRecent() {
    const latest = loadHistory()[0];
    if (latest) setPaymentId(latest.payment_id);
  }

  const heroKind = heroKindFor(result, error);
  const tierClass: Tier | undefined =
    result?.customer_tier === "silver" || result?.customer_tier === "gold"
      ? result.customer_tier
      : result?.customer_tier === "bronze"
        ? "bronze"
        : undefined;
  const tierColour = tierClass ? TIER_COLOURS[tierClass] : null;

  return (
    <section className="card status-page">
      <div className="card__header">
        <h2>Payment status</h2>
        <span className="card__sub">
          Look up any payment by id. Each lookup produces a traced fetch span you can
          pivot into Splunk APM.
        </span>
      </div>

      <form onSubmit={handleLookup} className="status-form">
        <div className="field">
          <label htmlFor="payment-id">Payment ID</label>
          <input
            id="payment-id"
            type="text"
            value={paymentId}
            onChange={(e) => setPaymentId(e.target.value)}
            placeholder="web-..."
            autoComplete="off"
            spellCheck={false}
          />
        </div>
        <div className="status-form__actions">
          <button className="primary" type="submit" disabled={submitting || paymentId.trim() === ""}>
            {submitting ? "Looking up\u2026" : "Look up"}
          </button>
          <button type="button" className="ghost" onClick={fillRecent} disabled={submitting}>
            Use my latest
          </button>
        </div>
      </form>

      {error && (
        <div className="status-detail status-detail--error" role="alert">
          <h3>Lookup failed</h3>
          <p>{error}</p>
          <p className="status-detail__hint">
            The api-gateway may be unreachable, or the id is malformed (alphanumeric,
            dot, dash and underscore only).
          </p>
        </div>
      )}

      {result && result.status === "not_found" && (
        <div className="status-detail status-detail--neutral">
          <h3>No payment with that id</h3>
          <p>
            The api-gateway has no record of <code>{result.payment_id}</code> in its
            in-memory buffer. The buffer rotates after 25 payments per pod, so very old
            ids will drop off.
          </p>
        </div>
      )}

      {result && result.status !== "not_found" && (
        <div className={`status-detail status-detail--${heroKind}`}>
          <header className="status-detail__hero">
            <div className="status-detail__hero-text">
              <h3>{(result.scheme ?? "Payment")} payment</h3>
              <span className="status-detail__id">
                <code>{result.payment_id}</code>
              </span>
            </div>
            <StatusPill status={result.status} />
          </header>

          <dl className="status-detail__grid">
            {typeof result.amount_minor_units === "number" && (
              <div>
                <dt>Amount</dt>
                <dd className="status-detail__amount">
                  {formatMinor(result.amount_minor_units, result.currency ?? "GBP")}
                </dd>
              </div>
            )}
            {result.scheme && (
              <div>
                <dt>Scheme</dt>
                <dd>{result.scheme}</dd>
              </div>
            )}
            {result.customer_id && (
              <div>
                <dt>Customer</dt>
                <dd>
                  <span>{result.customer_id}</span>
                  {tierColour && tierClass && (
                    <span
                      className="tier-chip"
                      style={{
                        background: tierColour.bg,
                        color: tierColour.fg,
                        marginLeft: 8,
                      }}
                    >
                      {tierLabel(tierClass)}
                    </span>
                  )}
                </dd>
              </div>
            )}
            {typeof result.submitted_at === "number" && (
              <div>
                <dt>Submitted</dt>
                <dd>
                  {formatClock(result.submitted_at * 1000)} ({formatRelative(result.submitted_at * 1000)})
                </dd>
              </div>
            )}
            {typeof result.downstream_errors === "number" && result.downstream_errors > 0 && (
              <div>
                <dt>Downstream errors</dt>
                <dd className="status-detail__warn">{result.downstream_errors}</dd>
              </div>
            )}
            {result.scenario && (
              <div>
                <dt>Scenario</dt>
                <dd className="mono">{result.scenario}</dd>
              </div>
            )}
            <div>
              <dt>Trace</dt>
              <dd>
                <TraceLink traceId={result.trace_id ?? null} realm={config.rumRealm} short={false} />
              </dd>
            </div>
            {result.message && (
              <div className="status-detail__full">
                <dt>Message</dt>
                <dd>{result.message}</dd>
              </div>
            )}
          </dl>
        </div>
      )}
    </section>
  );
}
