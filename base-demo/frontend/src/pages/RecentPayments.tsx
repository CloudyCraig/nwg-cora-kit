// Recent Payments — unified, auto-refreshing timeline.
//
// Compared to the previous build:
//   * The two side-by-side tables collapse into a single ordered list
//     with a Source badge ("gateway" or "this browser"), so the audience
//     sees one timeline rather than mentally merging two.
//   * Status is rendered as a colour-coded StatusPill (using the same
//     mapping as the Send Money success card and the Status page).
//   * Trace ids use the shared TraceLink chip — click to copy or
//     follow the APM pivot.
//   * The gateway feed auto-refreshes every 8 s with a visible
//     "Last updated" stamp so the audience sees movement without us
//     having to manually reload.
//   * Persona-aware: rows for *other* personas in the gateway feed are
//     dimmed (and badged "other persona") rather than hidden, so a
//     persona switch mid-demo doesn't make the whole table go empty
//     for a few seconds.

import { useEffect, useMemo, useRef, useState } from "react";

import { ServerRecentEntry, fetchRecentPayments } from "../api";
import StatusPill from "../components/StatusPill";
import TraceLink from "../components/TraceLink";
import { AppConfig } from "../config";
import { formatClock, formatMinor, formatRelative } from "../format";
import { HistoryEntry, loadHistory } from "../history";
import { usePersona } from "../PersonaContext";
import { TIER_COLOURS, Tier, tierLabel } from "../personas";

interface Props {
  config: AppConfig;
}

interface UnifiedRow {
  paymentId: string;
  whenMs: number;
  scheme: string;
  amountMinor: number;
  currency: string;
  customerId: string | null;
  customerTier: Tier;
  status: string;
  traceId: string | null;
  source: "gateway" | "local";
  // Whether this row's customer_id matches the active persona. Used to
  // dim cross-persona rows so the active customer's payments are visually
  // dominant without filtering the rest out entirely.
  matchesPersona: boolean;
}

type FilterKind = "all" | "mine" | "failed";

function tierFor(t: string | null | undefined): Tier {
  if (t === "silver" || t === "gold") return t;
  return "bronze";
}

function mergeRows(
  server: ServerRecentEntry[],
  local: HistoryEntry[],
  personaId: string,
): UnifiedRow[] {
  const seen = new Set<string>();
  const rows: UnifiedRow[] = [];
  for (const s of server) {
    if (!s.payment_id || seen.has(s.payment_id)) continue;
    seen.add(s.payment_id);
    rows.push({
      paymentId: s.payment_id,
      whenMs: s.submitted_at * 1000,
      scheme: s.scheme ?? "—",
      amountMinor: s.amount_minor_units,
      currency: s.currency ?? "GBP",
      customerId: s.customer_id,
      customerTier: tierFor(s.customer_tier),
      status: s.status,
      traceId: s.trace_id ?? null,
      source: "gateway",
      matchesPersona: s.customer_id === personaId,
    });
  }
  for (const l of local) {
    if (seen.has(l.payment_id)) continue;
    seen.add(l.payment_id);
    rows.push({
      paymentId: l.payment_id,
      whenMs: Date.parse(l.submitted_at) || 0,
      scheme: l.scheme,
      amountMinor: l.amount_minor_units,
      currency: l.currency,
      customerId: l.customer_id,
      customerTier: tierFor(l.customer_tier),
      status: l.status,
      traceId: l.trace_id ?? null,
      source: "local",
      matchesPersona: l.customer_id === personaId,
    });
  }
  rows.sort((a, b) => b.whenMs - a.whenMs);
  return rows;
}

const REFRESH_MS = 8_000;

export default function RecentPayments({ config }: Props) {
  const { persona } = usePersona();
  const [server, setServer] = useState<ServerRecentEntry[]>([]);
  const [local, setLocal] = useState<HistoryEntry[]>([]);
  const [loading, setLoading] = useState<boolean>(true);
  const [error, setError] = useState<string | null>(null);
  const [lastUpdated, setLastUpdated] = useState<number | null>(null);
  const [filter, setFilter] = useState<FilterKind>("all");
  const [now, setNow] = useState<number>(() => Date.now());
  const inFlight = useRef<boolean>(false);

  useEffect(() => {
    setLocal(loadHistory());
  }, []);

  // Poll the gateway every REFRESH_MS. We don't show a spinner on
  // subsequent fetches — only the initial load — because the talk-track
  // wants the table to feel like a live feed, not a UI that's
  // constantly "loading…". A flag prevents overlapping in-flight calls
  // if the network is slow.
  useEffect(() => {
    let cancelled = false;
    async function fetchOnce(isInitial: boolean) {
      if (inFlight.current) return;
      inFlight.current = true;
      try {
        const res = await fetchRecentPayments(config, 25);
        if (cancelled) return;
        setServer(res.items);
        setError(null);
        setLastUpdated(Date.now());
      } catch (err) {
        if (cancelled) return;
        const msg = err instanceof Error ? err.message : String(err);
        setError(msg);
      } finally {
        inFlight.current = false;
        if (isInitial && !cancelled) setLoading(false);
      }
    }
    fetchOnce(true);
    const handle = window.setInterval(() => fetchOnce(false), REFRESH_MS);
    return () => {
      cancelled = true;
      window.clearInterval(handle);
    };
  }, [config]);

  // 1 Hz clock so the "X seconds ago" stamp under "Last updated"
  // refreshes between fetches.
  useEffect(() => {
    const handle = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(handle);
  }, []);

  const rows = useMemo(
    () => mergeRows(server, local, persona.id),
    [server, local, persona.id],
  );

  const filtered = useMemo(() => {
    switch (filter) {
      case "mine":
        return rows.filter((r) => r.matchesPersona);
      case "failed":
        return rows.filter(
          (r) =>
            r.status === "declined"
            || r.status === "error"
            || r.status === "throttled"
            || r.status === "partial"
            || r.status.toLowerCase().includes("fail"),
        );
      default:
        return rows;
    }
  }, [rows, filter]);

  const mineCount = useMemo(() => rows.filter((r) => r.matchesPersona).length, [rows]);
  const failedCount = useMemo(() => rows.filter((r) =>
    r.status === "declined"
    || r.status === "error"
    || r.status === "throttled"
    || r.status === "partial"
    || r.status.toLowerCase().includes("fail"),
  ).length, [rows]);

  return (
    <section className="card recent-page">
      <div className="card__header card__header--wrap">
        <div>
          <h2>Recent payments</h2>
          <span className="card__sub">
            Live from <code>GET /api/recent</code>. Auto-refreshes every {REFRESH_MS / 1000}s.
          </span>
        </div>
        <div className="recent-page__status">
          {error ? (
            <span className="recent-page__updated recent-page__updated--error">
              Last fetch failed: {error}
            </span>
          ) : lastUpdated ? (
            <span className="recent-page__updated">
              Updated {formatRelative(lastUpdated)}
              <span className="recent-page__pulse" aria-hidden="true" />
            </span>
          ) : (
            <span className="recent-page__updated">Loading…</span>
          )}
          {/* The unused `now` value is referenced here so React keeps the
              relative-time stamp fresh between fetches. */}
          <span hidden>{now}</span>
        </div>
      </div>

      <div className="filter-chips" role="tablist" aria-label="Filter">
        <FilterChip
          active={filter === "all"}
          onClick={() => setFilter("all")}
          label="All"
          count={rows.length}
        />
        <FilterChip
          active={filter === "mine"}
          onClick={() => setFilter("mine")}
          label={`${persona.name}`}
          count={mineCount}
        />
        <FilterChip
          active={filter === "failed"}
          onClick={() => setFilter("failed")}
          label="Failed / throttled"
          count={failedCount}
        />
      </div>

      {loading && filtered.length === 0 && (
        <div className="status-line">Loading recent payments&hellip;</div>
      )}
      {!loading && filtered.length === 0 && (
        <div className="status-line">
          Nothing to show with this filter yet. Send a payment from{" "}
          <a href="/send">Send money</a> or wait for the traffic generator to
          land traffic on this gateway pod.
        </div>
      )}

      {filtered.length > 0 && (
        <table className="history recent-table">
          <thead>
            <tr>
              <th>When</th>
              <th>To</th>
              <th>Scheme</th>
              <th>Amount</th>
              <th>Customer</th>
              <th>Status</th>
              <th>Trace</th>
            </tr>
          </thead>
          <tbody>
            {filtered.map((row) => {
              const tierColour = TIER_COLOURS[row.customerTier];
              return (
                <tr
                  key={`${row.source}-${row.paymentId}`}
                  className={`recent-table__row${row.matchesPersona ? "" : " recent-table__row--dim"}`}
                >
                  <td>
                    <div className="recent-table__when">
                      <span>{formatClock(row.whenMs)}</span>
                      <span className="recent-table__when-sub">
                        {formatRelative(row.whenMs)}
                      </span>
                    </div>
                  </td>
                  <td>
                    <span className={`source-pill source-pill--${row.source}`}>
                      {row.source === "gateway" ? "Gateway" : "This browser"}
                    </span>
                  </td>
                  <td>{row.scheme}</td>
                  <td className="mono">{formatMinor(row.amountMinor, row.currency)}</td>
                  <td>
                    <div className="recent-table__customer">
                      <span className="recent-table__customer-id">{row.customerId ?? "—"}</span>
                      <span
                        className="tier-chip"
                        style={{ background: tierColour.bg, color: tierColour.fg }}
                      >
                        {tierLabel(row.customerTier)}
                      </span>
                    </div>
                  </td>
                  <td><StatusPill status={row.status} /></td>
                  <td>
                    <TraceLink traceId={row.traceId} realm={config.rumRealm} />
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </section>
  );
}

function FilterChip({
  active,
  onClick,
  label,
  count,
}: {
  active: boolean;
  onClick: () => void;
  label: string;
  count: number;
}) {
  return (
    <button
      type="button"
      role="tab"
      aria-selected={active}
      className={`filter-chip${active ? " filter-chip--active" : ""}`}
      onClick={onClick}
    >
      <span>{label}</span>
      <span className="filter-chip__count">{count}</span>
    </button>
  );
}
