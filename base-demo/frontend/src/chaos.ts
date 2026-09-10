// Thin fetch client for the chaos-controller HTTP API.
//
// All requests go to the same-origin `/chaos/api/*` path, which the
// web-frontend nginx reverse-proxies to the chaos-controller Service.
// Same-origin matters because (a) the RUM tracer's CORS trust list
// stays unchanged and (b) the presenter token rides on a static
// header rather than via the URL.
//
// The token itself is injected at SPA boot via /config.js (rendered
// from the chart-managed `chaos-controller-token` Secret). We never
// store it in localStorage / sessionStorage to keep it out of XSS
// payloads (codeguard-0-session-management-and-cookies).

import { AppConfig } from "./config";

export interface ScenarioParam {
  name: string;
  label: string;
  type: string; // "select" | (future: "number" | "text")
  options?: string[];
  default?: string;
}

export interface ScenarioStatus {
  state: "armed" | "clear" | "unknown";
  observed: Record<string, unknown>;
}

// "story" is the orchestrator category - long-running multi-act scenarios
// like payment-meltdown that wrap a sequence of single-act scenarios into
// one one-click button. Backend introduces categories independently of the
// SPA, so the union stays open-ended in practice; we still type the known
// ones so the renderer can pivot off them safely.
export interface ScenarioMeta {
  id: string;
  name: string;
  category: "story" | "app" | "latency" | "tier" | "infra";
  narrative: string;
  target_service: string;
  watch: string;
  recovery_hint: string;
  severity: "low" | "medium" | "high";
  param: ScenarioParam | null;
  requires_confirmation: boolean;
  status: ScenarioStatus;
}

export interface ScenarioCatalog {
  scenarios: ScenarioMeta[];
  armed_count: number;
  total: number;
}

export interface ChaosActionResult {
  scenario_id: string;
  action: "inject" | "clear";
  result: Record<string, unknown>;
  params?: Record<string, unknown>;
}

export class ChaosApiError extends Error {
  status: number;
  body: unknown;

  constructor(status: number, message: string, body: unknown) {
    super(message);
    this.name = "ChaosApiError";
    this.status = status;
    this.body = body;
  }
}

const BASE_URL = "/chaos/api";

function buildHeaders(
  config: AppConfig,
  extra: HeadersInit = {},
): HeadersInit {
  const out: Record<string, string> = {
    Accept: "application/json",
    ...(extra as Record<string, string>),
  };
  if (config.chaosToken) {
    out["X-Chaos-Token"] = config.chaosToken;
  }
  return out;
}

async function readJsonOrThrow<T>(res: Response): Promise<T> {
  const text = await res.text();
  let body: unknown = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = text;
  }
  if (!res.ok) {
    const message =
      (body && typeof body === "object" && "message" in body
        ? String((body as Record<string, unknown>).message)
        : `HTTP ${res.status}`) || `HTTP ${res.status}`;
    throw new ChaosApiError(res.status, message, body);
  }
  return body as T;
}

export async function fetchScenarios(
  config: AppConfig,
  signal?: AbortSignal,
): Promise<ScenarioCatalog> {
  const res = await fetch(`${BASE_URL}/scenarios`, {
    method: "GET",
    headers: buildHeaders(config),
    credentials: "omit",
    signal,
  });
  return readJsonOrThrow<ScenarioCatalog>(res);
}

export async function injectScenario(
  config: AppConfig,
  scenarioId: string,
  params: Record<string, unknown> | null,
  operator?: string,
): Promise<ChaosActionResult> {
  const headers = buildHeaders(config, { "Content-Type": "application/json" });
  if (operator) {
    (headers as Record<string, string>)["X-Operator"] = operator;
  }
  const res = await fetch(`${BASE_URL}/${encodeURIComponent(scenarioId)}/inject`, {
    method: "POST",
    headers,
    credentials: "omit",
    body: JSON.stringify(params ?? {}),
  });
  return readJsonOrThrow<ChaosActionResult>(res);
}

export async function clearScenario(
  config: AppConfig,
  scenarioId: string,
  operator?: string,
): Promise<ChaosActionResult> {
  const headers = buildHeaders(config, { "Content-Type": "application/json" });
  if (operator) {
    (headers as Record<string, string>)["X-Operator"] = operator;
  }
  const res = await fetch(`${BASE_URL}/${encodeURIComponent(scenarioId)}/clear`, {
    method: "POST",
    headers,
    credentials: "omit",
    body: "{}",
  });
  return readJsonOrThrow<ChaosActionResult>(res);
}

export async function recoverAll(
  config: AppConfig,
  operator?: string,
): Promise<{ action: "recover"; results: Record<string, unknown> }> {
  const headers = buildHeaders(config, { "Content-Type": "application/json" });
  if (operator) {
    (headers as Record<string, string>)["X-Operator"] = operator;
  }
  const res = await fetch(`${BASE_URL}/recover`, {
    method: "POST",
    headers,
    credentials: "omit",
    body: "{}",
  });
  return readJsonOrThrow<{
    action: "recover";
    results: Record<string, unknown>;
  }>(res);
}
