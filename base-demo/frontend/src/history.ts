// Tiny localStorage-backed history of submitted payments. Used by the
// "Recent Payments" page to give the demo a sense of statefulness even
// though the backend is fan-out only.

import { PaymentResponse } from "./api";
import { Persona, Tier } from "./personas";

const KEY = "natwest-demo-history";
const MAX = 25;

export interface HistoryEntry {
  payment_id: string;
  scheme: string;
  amount_minor_units: number;
  currency: string;
  channel: string;
  customer_id: string;
  customer_name: string;
  customer_tier: Tier;
  status: string;
  trace_id?: string;
  duration_ms?: number;
  submitted_at: string;
}

// Legacy entry shape (pre-tiers). Kept here only so loadHistory() can
// migrate older entries on first load instead of dropping the table.
interface LegacyHistoryEntry {
  payment_id?: unknown;
  scheme?: unknown;
  amount_minor_units?: unknown;
  currency?: unknown;
  channel?: unknown;
  customer_segment?: unknown;
  status?: unknown;
  trace_id?: unknown;
  duration_ms?: unknown;
  submitted_at?: unknown;
}

function isString(v: unknown): v is string {
  return typeof v === "string";
}

function migrateEntry(raw: unknown): HistoryEntry | null {
  if (!raw || typeof raw !== "object") return null;
  const candidate = raw as HistoryEntry & LegacyHistoryEntry;

  if (!isString(candidate.payment_id)) return null;

  // New shape - return as-is once we've sanity-checked the required keys.
  if (
    isString(candidate.customer_id) &&
    isString(candidate.customer_tier) &&
    isString(candidate.customer_name)
  ) {
    return candidate as HistoryEntry;
  }

  // Legacy shape - fold customer_segment into the new tier dimension and
  // synthesise a placeholder customer_id/name so the table renders.
  const segmentToTier: Record<string, Tier> = {
    retail: "bronze",
    premier: "silver",
    business: "gold",
  };
  const legacySegment = isString(candidate.customer_segment)
    ? candidate.customer_segment
    : "retail";
  const tier: Tier = segmentToTier[legacySegment] ?? "bronze";
  return {
    payment_id: candidate.payment_id,
    scheme: isString(candidate.scheme) ? candidate.scheme : "",
    amount_minor_units:
      typeof candidate.amount_minor_units === "number"
        ? candidate.amount_minor_units
        : 0,
    currency: isString(candidate.currency) ? candidate.currency : "GBP",
    channel: isString(candidate.channel) ? candidate.channel : "web",
    customer_id: "(legacy)",
    customer_name: legacySegment,
    customer_tier: tier,
    status: isString(candidate.status) ? candidate.status : "unknown",
    trace_id: isString(candidate.trace_id) ? candidate.trace_id : undefined,
    duration_ms:
      typeof candidate.duration_ms === "number"
        ? candidate.duration_ms
        : undefined,
    submitted_at: isString(candidate.submitted_at)
      ? candidate.submitted_at
      : new Date(0).toISOString(),
  };
}

export function loadHistory(): HistoryEntry[] {
  try {
    const raw = window.localStorage.getItem(KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return [];
    const migrated: HistoryEntry[] = [];
    for (const item of parsed) {
      const next = migrateEntry(item);
      if (next) migrated.push(next);
    }
    return migrated;
  } catch {
    return [];
  }
}

export function appendHistory(entry: HistoryEntry): HistoryEntry[] {
  const current = loadHistory();
  const next = [entry, ...current].slice(0, MAX);
  try {
    window.localStorage.setItem(KEY, JSON.stringify(next));
  } catch {
    // Quota or private mode - silently swallow; demo doesn't need to
    // persist beyond the tab.
  }
  return next;
}

export function summariseResponse(
  payload: {
    payment_id: string;
    scheme: string;
    amount_minor_units: number;
    currency: string;
    channel: string;
    customer_id: string;
    customer_tier: Tier;
  },
  response: PaymentResponse,
  persona: Persona,
): HistoryEntry {
  return {
    payment_id: payload.payment_id,
    scheme: payload.scheme,
    amount_minor_units: payload.amount_minor_units,
    currency: payload.currency,
    channel: payload.channel,
    customer_id: payload.customer_id,
    customer_name: persona.name,
    customer_tier: payload.customer_tier,
    status: response.status ?? "unknown",
    trace_id: typeof response.trace_id === "string" ? response.trace_id : undefined,
    duration_ms:
      typeof response.duration_ms === "number" ? response.duration_ms : undefined,
    submitted_at: new Date().toISOString(),
  };
}
