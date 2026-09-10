# Drift: base-demo/ (April repo) vs the live environment (Sep 2026)

`base-demo/` is Marc's original repo **including 121 uncommitted working-tree
changes** made May–Sep (list: `cluster-snapshot/base-repo-uncommitted-files.txt`).
The live exports in `itsi-export/`, `cluster-snapshot/` and `splunk-box/` are the
source of truth for current state. Headlines a rebuilder must know:

## Infrastructure
- **Nodes**: t3.xlarge nodegroup `ng-nwg` REPLACED by **m5.xlarge `ng-nwg-m5`**
  (2026-09-04) after t3 burst-credit throttling took the demo down. Never use
  burstable instances for this demo. Spec: `infra/CLUSTER-SPEC.md`.
- Kubernetes 1.31 (control plane + nodes); eksctl-created cluster `nwg-demo`, eu-west-1.
- Splunk box nginx: port-80 server block now serves `/__proxy_health` for the
  `natwest-spa-watchdog` timer (certbot's rewrite had broken it → nginx restart
  loop every 62s for weeks). Current files: `splunk-box/`. spa.conf hard-codes
  node private IPs (NodePorts 30598/30680) — re-point after any node change.

## AI layer (all NEW since April — the kit's main subject)
- cora-agent / cora-otelcol / cora-loadgen (see top-level kit dirs + README).
- Frontend: CoraChat widget, CoraTrafficCard presenter toggle, /cora/api proxy,
  partial→decline handling in SendMoney (these live UNCOMMITTED in base-demo).
- O11y org: telemetry now flows to the main demo org (was a separate AI trial
  org); cora-otelcol owns the AI-scoped ingest token; traces single-path.

## ITSI (live export = itsi-export/, 40 services / 185 KPIs)
- NEW: "AI agents" service (3 KPIs, entity breakdown by agent), entity type
  "AI Agent" + entity with O11y drilldowns.
- 136 KPIs had native alert rules enabled (2026-07-07); +5 KPI correlation
  searches for RCA signals; TE correlation search rewritten to path-vis;
  SLO search per-service; Madrid p95 search generalised to all locations.
- Glass tables (exports carry every fix): exec view v3 — trend semantics =
  % deviation vs 8h median, fraud-tile colour rules, 120s refresh, caption;
  plus craigs_digital_experience.

## ThousandEyes
- The STREAMING generation of /api/process tests lives in account group
  `cgorman` (aid 2138186), retargeted to **https://** (http→301 = permanent
  fail). Older mserieys-group + dead-hostname generations still exist — do not
  resurrect them. Exports: `thousandeyes/http_server_tests.json` (redacted).

## Gotcha index (cost real hours; full stories in the Word guide + README)
ingest-token needs ai_monitoring ROLE • send_otlp_histograms BEFORE first
emission • gen_ai.cost.* protected namespace • delta temporality + message
content required • LLM connection needs DATED model id • KPI windows are 5-min
sums • configmap→pod sync ~80s • HEC endpoint is bare host:port • traffic
toggle resets OFF on agent restart • CORA_BACKEND_* naming (docker-link clash)
