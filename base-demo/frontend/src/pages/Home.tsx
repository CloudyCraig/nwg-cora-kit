// Home — the SPA's landing page after sign-in.
//
// Renders an account header (sort code, masked account number, available
// balance) for the active persona, a row of quick-action chips, and a
// short list of recent activity merged from the api-gateway's in-memory
// buffer (GET /api/recent) and the browser's local history.
//
// The screen is purely cosmetic: nothing here drives RUM page actions
// (that would dilute the "Send payment" signal demo'd from the Send
// Money page). The point of Home is to make the SPA read like a real
// online-banking app the moment the audience lands on it.

import { useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";

import { ServerRecentEntry, fetchRecentPayments } from "../api";
import StatusPill from "../components/StatusPill";
import { AppConfig } from "../config";
import {
  formatClock,
  formatMinor,
  formatRelative,
  formatSortCode,
  maskAccount,
} from "../format";
import { loadHistory, HistoryEntry } from "../history";
import { usePersona } from "../PersonaContext";
import { TIER_COLOURS, tierLabel } from "../personas";
import { accountFor } from "../accounts";

interface Props {
  config: AppConfig;
}

// Greeting based on the wall-clock hour. Plain UK English; falls back to
// the all-day "Hello" if Date is unavailable for any reason.
function greetingFor(name: string): string {
  try {
    const hour = new Date().getHours();
    if (hour < 12) return `Good morning, ${name}`;
    if (hour < 18) return `Good afternoon, ${name}`;
    return `Good evening, ${name}`;
  } catch {
    return `Hello, ${name}`;
  }
}

// Merge the server and local activity feeds into a single chronological
// list. Server entries are authoritative for status (the local entry
// captures whatever the SPA happened to read at submit time, which can
// drift if the gateway later retried). We dedupe by payment_id, keeping
// the server copy.
interface UnifiedRow {
  paymentId: string;
  whenMs: number;
  scheme: string | null;
  amountMinor: number;
  currency: string;
  status: string;
  traceId: string | null;
  source: "gateway" | "local";
}

function mergeActivity(
  server: ServerRecentEntry[],
  local: HistoryEntry[],
  personaId: string,
): UnifiedRow[] {
  const seen = new Set<string>();
  const rows: UnifiedRow[] = [];
  for (const s of server) {
    if (s.customer_id && s.customer_id !== personaId) continue;
    if (!s.payment_id || seen.has(s.payment_id)) continue;
    seen.add(s.payment_id);
    rows.push({
      paymentId: s.payment_id,
      whenMs: s.submitted_at * 1000,
      scheme: s.scheme,
      amountMinor: s.amount_minor_units,
      currency: s.currency ?? "GBP",
      status: s.status,
      traceId: s.trace_id ?? null,
      source: "gateway",
    });
  }
  for (const l of local) {
    if (l.customer_id !== personaId) continue;
    if (seen.has(l.payment_id)) continue;
    seen.add(l.payment_id);
    rows.push({
      paymentId: l.payment_id,
      whenMs: Date.parse(l.submitted_at) || 0,
      scheme: l.scheme,
      amountMinor: l.amount_minor_units,
      currency: l.currency,
      status: l.status,
      traceId: l.trace_id ?? null,
      source: "local",
    });
  }
  rows.sort((a, b) => b.whenMs - a.whenMs);
  return rows;
}

const QUICK_ACTIONS: Array<{
  to: string;
  label: string;
  hint: string;
  icon: string;
}> = [
  { to: "/send", label: "Send money", hint: "To a saved payee or new", icon: "\u2197" },
  { to: "/send?intent=bill", label: "Pay bill", hint: "Direct debits & top-ups", icon: "\u{1F4DD}" },
  { to: "/send?intent=transfer", label: "Transfer", hint: "Between your accounts", icon: "\u{1F501}" },
  { to: "/recent", label: "Statements", hint: "See recent activity", icon: "\u{1F4C4}" },
];

export default function Home({ config }: Props) {
  const { persona } = usePersona();
  const tierColour = TIER_COLOURS[persona.tier];
  const account = accountFor(persona);

  const [server, setServer] = useState<ServerRecentEntry[]>([]);
  const [local, setLocal] = useState<HistoryEntry[]>([]);
  const [loading, setLoading] = useState<boolean>(true);

  // Pull the gateway feed once on mount, plus a slow refresh so the
  // preview doesn't go stale during a long demo. We deliberately keep
  // this poll slower than the Recent Payments page (which refreshes
  // every 8 s) — the audience usually only sees Home for a few seconds
  // before clicking into Send Money, so a 30 s refresh is plenty.
  useEffect(() => {
    let cancelled = false;
    setLocal(loadHistory());

    async function load() {
      try {
        const res = await fetchRecentPayments(config, 25);
        if (!cancelled) setServer(res.items);
      } catch {
        if (!cancelled) setServer([]);
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    load();
    const handle = window.setInterval(load, 30_000);
    return () => {
      cancelled = true;
      window.clearInterval(handle);
    };
  }, [config]);

  const activity = useMemo(
    () => mergeActivity(server, local, persona.id).slice(0, 5),
    [server, local, persona.id],
  );

  return (
    <>
      {/* Greeting + account hero ----------------------------------------- */}
      <section className="account-hero" aria-label="Account summary">
        <div className="account-hero__greeting">
          <h2 className="account-hero__hello">{greetingFor(persona.name)}</h2>
          <span
            className="tier-chip"
            style={{ background: tierColour.bg, color: tierColour.fg }}
          >
            {tierLabel(persona.tier)} customer
          </span>
        </div>
        <div className="account-hero__card">
          <div className="account-hero__meta">
            <span className="account-hero__product">{account.productName}</span>
            <span className="account-hero__numbers">
              <span>Sort code {formatSortCode(account.sortCode)}</span>
              <span aria-hidden="true">&middot;</span>
              <span>Account {maskAccount(account.accountNumber)}</span>
            </span>
          </div>
          <div className="account-hero__balance">
            <span className="account-hero__balance-label">Available balance</span>
            <span className="account-hero__balance-amount">
              {formatMinor(account.availableBalanceMinor)}
            </span>
            <span className="account-hero__balance-sub">
              of which {formatMinor(account.overdraftLimitMinor)} is arranged overdraft
            </span>
          </div>
        </div>
      </section>

      {/* Quick actions --------------------------------------------------- */}
      <section className="quick-actions" aria-label="Quick actions">
        {QUICK_ACTIONS.map((qa) => (
          <Link key={qa.to} to={qa.to} className="quick-action">
            <span className="quick-action__icon" aria-hidden="true">{qa.icon}</span>
            <span className="quick-action__body">
              <span className="quick-action__label">{qa.label}</span>
              <span className="quick-action__hint">{qa.hint}</span>
            </span>
          </Link>
        ))}
      </section>

      {/* Recent activity preview ---------------------------------------- */}
      <section className="card">
        <div className="card__header">
          <h2>Recent activity</h2>
          <Link to="/recent" className="card__link">See all</Link>
        </div>
        {loading && activity.length === 0 && (
          <div className="status-line">Loading recent payments&hellip;</div>
        )}
        {!loading && activity.length === 0 && (
          <div className="status-line">
            Nothing in this account&apos;s recent activity yet. Send a payment
            from <Link to="/send">Send money</Link> to populate the timeline.
          </div>
        )}
        {activity.length > 0 && (
          <ul className="activity-list">
            {activity.map((row) => (
              <li key={row.paymentId} className="activity-row">
                <div className="activity-row__main">
                  <span className="activity-row__title">
                    {row.scheme ?? "Payment"} payment
                  </span>
                  <span className="activity-row__meta">
                    {formatClock(row.whenMs)} &middot; {formatRelative(row.whenMs)}
                    {row.source === "local" && (
                      <span className="activity-row__pill" title="Submitted from this browser">
                        this browser
                      </span>
                    )}
                  </span>
                </div>
                <div className="activity-row__right">
                  <span className="activity-row__amount">
                    {formatMinor(row.amountMinor, row.currency)}
                  </span>
                  <StatusPill status={row.status} />
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>
    </>
  );
}
