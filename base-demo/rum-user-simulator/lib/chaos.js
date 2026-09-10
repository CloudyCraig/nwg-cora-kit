// Chaos-controller state poller.
//
// The chaos-controller exposes `/chaos/api/scenarios` (list all scenarios
// with per-scenario `status.state` in { "armed", "clear" }). We poll it
// every `chaosPollSeconds` and cache the last successful result. The
// Madrid city loop reads the cache each iteration.
//
// We DO NOT trigger scenarios from here — this is read-only. The token
// is still required because the endpoint refuses anonymous requests, and
// the safety story of chaos-controller-token is unchanged.
//
// Failure mode: if the chaos-controller is down or misbehaves we fall
// back to `state = "clear"` for every scenario so Madrid stays on the
// healthy path. Better a false-clear than a false-armed (a false-armed
// would spam rage-clicks + degraded-flag RUM events against a healthy
// backend, which would poison the dashboards).

import { config, log } from "./config.js";

let lastSnapshot = { fetchedAt: 0, byScenario: new Map(), reachable: false };

function toMap(scenariosArr) {
  const m = new Map();
  if (!Array.isArray(scenariosArr)) return m;
  for (const s of scenariosArr) {
    if (!s || typeof s.id !== "string") continue;
    const state =
      (s.status && typeof s.status.state === "string" && s.status.state) ||
      "clear";
    m.set(s.id, state);
  }
  return m;
}

// One-shot poll. Never throws — errors are logged and the previous
// snapshot is left in place. Uses Node's built-in fetch (Node 20+).
async function pollOnce() {
  const url = `${config.chaosUrl.replace(/\/+$/, "")}/chaos/api/scenarios`;
  const controller = new AbortController();
  const t = setTimeout(() => controller.abort(), 4000);
  try {
    const resp = await fetch(url, {
      method: "GET",
      headers: {
        "X-Chaos-Token": config.chaosToken,
        "X-Operator": "rum-user-simulator",
      },
      signal: controller.signal,
    });
    if (!resp.ok) {
      log("warn", "chaos_poll_http_error", { status: resp.status, url });
      return;
    }
    const body = await resp.json();
    const byScenario = toMap(body && body.scenarios);
    lastSnapshot = { fetchedAt: Date.now(), byScenario, reachable: true };
  } catch (err) {
    log("warn", "chaos_poll_failed", {
      error: err instanceof Error ? err.message : String(err),
      url,
    });
  } finally {
    clearTimeout(t);
  }
}

// Returns the set of scenario ids the caller cares about that are
// currently armed. If we've never had a successful poll we return an
// empty set (fail-safe: healthy behaviour).
export function armedFrom(scenarioIds) {
  const out = [];
  for (const id of scenarioIds) {
    if (lastSnapshot.byScenario.get(id) === "armed") out.push(id);
  }
  return out;
}

export function pollerHealth() {
  return {
    reachable: lastSnapshot.reachable,
    ageSeconds: lastSnapshot.fetchedAt
      ? Math.round((Date.now() - lastSnapshot.fetchedAt) / 1000)
      : null,
    scenarioCount: lastSnapshot.byScenario.size,
  };
}

// Start the poll loop. Returns a stop() function so run.js can shut it
// down on SIGTERM (kubectl scale --replicas=0 / helm rollback).
export function startChaosPoller() {
  let stopped = false;
  let handle = null;
  const tick = async () => {
    if (stopped) return;
    await pollOnce();
    if (stopped) return;
    handle = setTimeout(tick, config.chaosPollSeconds * 1000);
    // Node keeps the process alive as long as there's a pending timer;
    // that's exactly what we want here.
  };
  // Fire the first poll immediately so the Madrid loop's first iteration
  // has real data. If it fails we still start the periodic loop.
  void tick();
  return function stop() {
    stopped = true;
    if (handle) clearTimeout(handle);
  };
}
