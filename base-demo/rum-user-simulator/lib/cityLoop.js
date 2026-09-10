// Per-city session loop. One loop per enabled city; loops run in parallel
// so a slow Madrid session doesn't stall London/Frankfurt.
//
// The Madrid loop reads the chaos-poller cache each iteration and
// branches on it — the poll itself runs on its own timer in chaos.js so
// a slow chaos-controller doesn't stretch the per-session budget.

import { armedFrom } from "./chaos.js";
import { config, log } from "./config.js";
import { runSession } from "./session.js";

// Compute the desired mode for one loop iteration.
// Non-chaos-aware cities always run healthy.
function pickMode(city) {
  if (!city.chaosAware) return "healthy";
  const armed = armedFrom(config.madridChaosScenarios);
  return armed.length > 0 ? "chaos" : "healthy";
}

export function startCityLoop(cityKey, city) {
  let stopped = false;
  let handle = null;

  const tick = async () => {
    if (stopped) return;
    const mode = pickMode(city);
    const startedAt = Date.now();
    log("info", "session_start", {
      city: cityKey,
      mode,
      persona: city.personaId,
    });
    const result = await runSession({ cityKey, city, mode });
    log(result.ok ? "info" : "warn", "session_done", {
      city: cityKey,
      mode: result.mode,
      ok: result.ok,
      duration_ms: result.durationMs,
      error: result.error || null,
    });

    if (stopped) return;
    // Cadence is measured start→start. If the session ran long we tick
    // again immediately (bounded so we don't machine-gun on a broken SPA).
    const elapsed = Date.now() - startedAt;
    const delay = Math.max(1000, config.cadenceSeconds * 1000 - elapsed);
    handle = setTimeout(tick, delay);
  };

  // Stagger the initial fire so the three cities don't all launch a
  // Chromium context at the exact same instant. Small stagger keeps
  // Chromium boot times evenly spread across the CPU budget.
  const staggerMs = Math.floor(Math.random() * 3000);
  handle = setTimeout(tick, staggerMs);

  return function stop() {
    stopped = true;
    if (handle) clearTimeout(handle);
  };
}
