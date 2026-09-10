// Small formatting helpers used across the SPA. Centralised here so the
// account hero, payee chips, status pages and the recent-payments table
// all render currency / dates / IDs the same way.

const GBP = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

// Format a minor-units integer (pence) as a friendly GBP/EUR/USD amount.
// Intl handles the currency symbol; we always pass minor-units so we
// avoid floating-point drift when the SPA round-trips through the form.
export function formatMinor(minor: number, currency: string = "GBP"): string {
  if (currency === "GBP") {
    return GBP.format(minor / 100);
  }
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency,
    minimumFractionDigits: 2,
  }).format(minor / 100);
}

// Parse a free-text amount entered by the user as pounds-and-pence ("12.50",
// "1,250.00", "£12") into minor-units. Returns NaN if the input is empty or
// can't be coerced to a positive number.
export function parsePoundsToMinor(input: string): number {
  if (typeof input !== "string") return NaN;
  // Strip currency markers and thousands separators before parseFloat.
  const cleaned = input.replace(/[£,\s]/g, "");
  if (cleaned === "") return NaN;
  const n = Number.parseFloat(cleaned);
  if (!Number.isFinite(n) || n <= 0) return NaN;
  return Math.round(n * 100);
}

// Convert a minor-units amount to a string suitable for a numeric input.
// Always two-decimal so the form doesn't bounce between "12" and "12.00"
// while the user types.
export function minorToPoundsString(minor: number): string {
  return (minor / 100).toFixed(2);
}

// Human "5 minutes ago" / "just now" relative time. The Recent Payments
// page and the Home page activity preview both want it, with consistent
// thresholds.
export function formatRelative(when: Date | number): string {
  const ts = typeof when === "number" ? when : when.getTime();
  const diff = Date.now() - ts;
  if (diff < 0) return "just now";
  const seconds = Math.floor(diff / 1000);
  if (seconds < 10) return "just now";
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} hr ago`;
  const days = Math.floor(hours / 24);
  return `${days} day${days === 1 ? "" : "s"} ago`;
}

// HH:MM, locale-aware. Used on the Recent Payments table so the column
// stays narrow.
export function formatClock(when: Date | number): string {
  const d = when instanceof Date ? when : new Date(when);
  return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

// Format a UK sort code as XX-XX-XX. Input must be six digits; anything
// else is returned untouched so the UI never throws on bad input.
export function formatSortCode(raw: string): string {
  if (!/^\d{6}$/.test(raw)) return raw;
  return `${raw.slice(0, 2)}-${raw.slice(2, 4)}-${raw.slice(4, 6)}`;
}

// Mask all but the last 4 digits of an account number for the account hero
// and payee chips. Returns "•••• 1234" — the bullet character renders
// cleanly across browsers (unlike the older "**** 1234" ASCII variant).
export function maskAccount(raw: string): string {
  const tail = raw.slice(-4);
  return `\u2022\u2022\u2022\u2022 ${tail}`;
}

// Splunk Observability APM-trace URL. Falls back to a tenant-agnostic
// search if the realm isn't configured (e.g. local `vite dev`). Mirrors
// the helper inside PresenterHUD.tsx — kept duplicated rather than
// extracted into a shared module because the HUD is a closed read-only
// surface and we don't want non-presenter pages to import its internals.
export function apmTraceUrl(realm: string | undefined, traceId: string): string {
  if (!realm) {
    return `https://app.signalfx.com/#/apm/traces/${encodeURIComponent(traceId)}`;
  }
  return `https://app.${realm}.signalfx.com/#/apm/traces/${encodeURIComponent(traceId)}`;
}

// Short rendering of a trace id for table cells. Splunk trace ids are
// 32-hex-character strings, which always blow out a column even on a
// wide monitor; show the first 12 and trail with a Unicode ellipsis.
export function shortTrace(traceId: string): string {
  if (!traceId) return "—";
  if (traceId.length <= 14) return traceId;
  return `${traceId.slice(0, 12)}\u2026`;
}
