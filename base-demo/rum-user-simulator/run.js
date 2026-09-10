// rum-user-simulator entrypoint.
//
// Boots the chaos-controller poller and one session loop per enabled
// city. Handles SIGTERM cleanly so `kubectl scale --replicas=0` (or a
// helm rollback) stops all in-flight work within a few seconds.

import { startCityLoop } from "./lib/cityLoop.js";
import { pollerHealth, startChaosPoller } from "./lib/chaos.js";
import { closeBrowser } from "./lib/session.js";
import { config, log } from "./lib/config.js";

const enabledCities = Object.keys(config.cities);
if (enabledCities.length === 0) {
  log("warn", "no_cities_enabled_exiting", {});
  process.exit(0);
}

log("info", "sim_boot", {
  spa_url: config.spaUrl,
  chaos_url: config.chaosUrl,
  cadence_s: config.cadenceSeconds,
  chaos_poll_s: config.chaosPollSeconds,
  cities: enabledCities,
  madrid_chaos_scenarios: config.madridChaosScenarios,
});

const stopChaos = startChaosPoller();
const stopCityLoops = enabledCities.map((k) => startCityLoop(k, config.cities[k]));

// Light heartbeat every 60 s so `kubectl logs` shows liveness even when
// no session started/ended in the last window. Also surfaces the chaos-
// poller's health so an ops-observer can spot a token/network break.
const heartbeat = setInterval(() => {
  log("info", "heartbeat", { chaos: pollerHealth() });
}, 60_000);

function shutdown(reason) {
  log("info", "sim_shutdown", { reason });
  clearInterval(heartbeat);
  try { stopChaos(); } catch (_e) { /* ignore */ }
  for (const stop of stopCityLoops) {
    try { stop(); } catch (_e) { /* ignore */ }
  }
  // Give in-flight session loops ~5s to close their browser contexts
  // gracefully; then force-exit so the pod terminates well within the
  // default 30 s termination grace.
  setTimeout(async () => {
    try { await closeBrowser(); } catch (_e) { /* ignore */ }
    process.exit(0);
  }, 5000).unref();
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
process.on("uncaughtException", (err) => {
  log("error", "uncaught_exception", { error: err.message, stack: err.stack });
});
process.on("unhandledRejection", (err) => {
  log("error", "unhandled_rejection", {
    error: err instanceof Error ? err.message : String(err),
  });
});
