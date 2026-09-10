import { AppConfig } from "./config";
import { DEFAULT_PERSONA_ID, PERSONAS, Tier, findPersona } from "./personas";

// One-shot payment payload mirroring what the traffic generator sends.
// Kept in sync with traffic-generator/generate.py::_build_payload so the
// service map sees identical shape from both sources.
//
// customer_id / customer_tier replace the legacy customer_segment field.
// They are populated from the active PersonaContext on submit; the back-end
// uses them to set customer.id and customer.tier span attributes (powers
// dashboards in terraform/dashboard.tf).
//
// customer_location / customer_country / customer_region (optional) match
// the LOCATIONS table in traffic-generator/generate.py. When set, the
// gateway tags them on every span so APM / RUM / ITSI pivots by location
// work for SPA-driven traffic the same way they do for synthetic load.
export interface PaymentRequest {
  payment_id: string;
  // SEPA is the natural rail for the EU personas added in personas.ts
  // (Sofia/Klaus/Sophie/Marco). Backend audit.py and the traffic
  // generator already emit SEPA on the scheme attribute; this just
  // unblocks the SPA from initiating SEPA payments when an EU persona
  // is active.
  scheme: "FPS" | "BACS" | "CHAPS" | "SWIFT" | "SEPA";
  amount_minor_units: number;
  currency: "GBP" | "EUR" | "USD";
  debtor_country: string;
  creditor_country: string;
  channel: "web" | "mobile" | "branch";
  customer_id: string;
  customer_tier: Tier;
  customer_location?: string;
  customer_country?: string;
  customer_region?: string;
  customer_lat?: number;
  customer_lon?: number;
}

export interface PaymentResponse {
  status: string;
  payment_id?: string;
  trace_id?: string;
  duration_ms?: number;
  [key: string]: unknown;
}

function newPaymentId(): string {
  // crypto.randomUUID is available in all evergreen browsers; the demo
  // doesn't ship to legacy. Falls back to a Math.random suffix only if
  // the API is missing (e.g. in a non-secure context iframe).
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) {
    return `web-${crypto.randomUUID()}`;
  }
  return `web-${Math.random().toString(36).slice(2)}-${Date.now()}`;
}

export function buildSamplePayment(
  overrides: Partial<PaymentRequest> = {},
  config?: AppConfig,
): PaymentRequest {
  // Default to the persona seeded by personas.ts so initial form state is
  // self-consistent even before PersonaContext is read by the page.
  const defaultPersona = findPersona(DEFAULT_PERSONA_ID) ?? PERSONAS[0]!;
  // The channel field is the "web" / "mobile" dimension carried on every
  // span attribute via api-gateway. Gets sourced from AppConfig.channel
  // when present (set by config.ts::detectChannel from the URL query),
  // overridable per-call via overrides.channel.
  const defaultChannel: PaymentRequest["channel"] =
    config?.channel === "mobile" ? "mobile" : "web";
  const base: PaymentRequest = {
    payment_id: newPaymentId(),
    scheme: "FPS",
    amount_minor_units: 12_500,
    currency: "GBP",
    debtor_country: "GB",
    creditor_country: "GB",
    channel: defaultChannel,
    customer_id: defaultPersona.id,
    customer_tier: defaultPersona.tier,
  };
  if (defaultPersona.location) {
    base.customer_location = defaultPersona.location.city;
    base.customer_country = defaultPersona.location.country;
    base.customer_region = defaultPersona.location.region;
    base.customer_lat = defaultPersona.location.lat;
    base.customer_lon = defaultPersona.location.lon;
  }
  return { ...base, ...overrides };
}

export async function submitPayment(
  config: AppConfig,
  payload: PaymentRequest,
): Promise<PaymentResponse> {
  const url = `${config.gatewayUrl.replace(/\/$/, "")}/process`;
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
    // The gateway is on the same EKS cluster behind a LoadBalancer; the
    // RUM SDK auto-injects traceparent because we listed the gateway
    // origin in propagateTraceHeaderCorsUrls.
    credentials: "omit",
  });

  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`gateway returned ${res.status}: ${body || res.statusText}`);
  }
  return (await res.json()) as PaymentResponse;
}

// Server-side recent-payments entry as returned by GET /api/recent on the
// api-gateway. Mirrors app/service.py::recent so we can render the row
// without a second model. The server returns numeric epoch seconds for
// submitted_at (cheaper to JSON-serialize than ISO strings); the SPA
// converts on render.
export interface ServerRecentEntry {
  payment_id: string;
  scheme: string | null;
  amount_minor_units: number;
  currency: string | null;
  channel: string | null;
  customer_id: string | null;
  customer_tier: "bronze" | "silver" | "gold";
  scenario: string;
  status: string;
  downstream_errors: number;
  submitted_at: number;
  trace_id: string | null;
}

export interface ServerRecentResponse {
  service: string;
  count: number;
  items: ServerRecentEntry[];
}

// GET /api/recent. Hits the api-gateway's read endpoint, which on success
// produces a Server-Timing response header that lets Splunk RUM draw the
// "View APM trace" pivot for the corresponding fetch span.
export async function fetchRecentPayments(
  config: AppConfig,
  limit = 25,
): Promise<ServerRecentResponse> {
  const base = config.gatewayUrl.replace(/\/$/, "");
  const url = `${base}/recent?limit=${encodeURIComponent(String(limit))}`;
  const res = await fetch(url, {
    method: "GET",
    headers: { Accept: "application/json" },
    credentials: "omit",
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(
      `gateway /recent returned ${res.status}: ${body || res.statusText}`,
    );
  }
  return (await res.json()) as ServerRecentResponse;
}

// Status response for GET /api/status/<payment_id>. The server returns
// either a populated record (status="accepted"|"partial"|...) or a
// not-found marker (status="not_found") - both are 200, so the SPA can
// render a friendly message without retrying.
export interface ServerStatusResponse {
  service: string;
  payment_id: string;
  status: string;
  message?: string;
  scheme?: string | null;
  amount_minor_units?: number;
  currency?: string | null;
  customer_tier?: "bronze" | "silver" | "gold";
  customer_id?: string | null;
  submitted_at?: number;
  trace_id?: string | null;
  scenario?: string;
  downstream_errors?: number;
}

// POST /api/auth/event. Beacon to the api-gateway audit pipeline so
// SPA login / logout flows surface in the nwpay_audit Splunk index. The
// SPA never blocks on this call; failures are intentionally swallowed
// (codeguard-0-authentication-mfa: don't oracle auth state). The gateway
// itself returns 204 on every code path.
export async function emitAuthBeacon(
  config: AppConfig,
  payload: { username: string; outcome: "success" | "failed" | "logout"; mfa?: boolean },
): Promise<void> {
  const base = config.gatewayUrl.replace(/\/$/, "");
  const url = `${base}/auth/event`;
  try {
    await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ...payload, mfa: !!payload.mfa }),
      credentials: "omit",
      keepalive: true,
    });
  } catch {
    // Beacon: never throw to caller. Audit gaps surface as missing
    // events in Splunk dashboards, not as broken UX.
  }
}

export type NetworkBeaconPayload = {
  session_id?: string | null;
  customer_id?: string | null;
  customer_tier?: string | null;
  effective_type: string;
  previous_effective_type?: string | null;
  downlink_mbps?: number | null;
  rtt_ms?: number | null;
  save_data?: boolean;
  source: "session_start" | "change";
};

// POST /api/network/event. Bridges the browser's Network Information API
// reading into Splunk Enterprise so the ITSI correlation search
// `[NatWest demo] SPA network connection changed` can fire on
// intermittent connectivity. The same data lives in Splunk Observability
// (RUM, as the `network.context` recordPageAction span); this beacon
// makes the signal also reachable from ITSI without forcing the audience
// to context-switch.
//
// Same shape as emitAuthBeacon: keepalive POST, gateway returns 204 on
// every code path, failures are swallowed so the SPA never breaks.
export async function emitNetworkBeacon(
  config: AppConfig,
  payload: NetworkBeaconPayload,
): Promise<void> {
  const base = config.gatewayUrl.replace(/\/$/, "");
  const url = `${base}/network/event`;
  try {
    await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        ...payload,
        save_data: !!payload.save_data,
      }),
      credentials: "omit",
      keepalive: true,
    });
  } catch {
    // Beacon: never throw to caller. Same rationale as emitAuthBeacon.
  }
}

// GET /api/status/<payment_id>. Validates the id client-side to avoid
// shipping arbitrary user input into a URL path; the api-gateway handler
// is also defensive but the cheaper test is here.
export async function fetchPaymentStatus(
  config: AppConfig,
  paymentId: string,
): Promise<ServerStatusResponse> {
  if (!/^[A-Za-z0-9_.\-]{1,128}$/.test(paymentId)) {
    throw new Error("payment id must be alphanumeric / dot / dash / underscore");
  }
  const base = config.gatewayUrl.replace(/\/$/, "");
  const url = `${base}/status/${encodeURIComponent(paymentId)}`;
  const res = await fetch(url, {
    method: "GET",
    headers: { Accept: "application/json" },
    credentials: "omit",
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(
      `gateway /status returned ${res.status}: ${body || res.statusText}`,
    );
  }
  return (await res.json()) as ServerStatusResponse;
}
