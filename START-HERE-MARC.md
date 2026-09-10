# Hi Marc 👋

This repo now contains **everything needed to rebuild the whole NWG demo from
bare AWS** — cluster, payments microservices, chaos controller, traffic
generator, SPA, Splunk box — plus the **AI-assistant layer** Craig added on
top (agent, AI Agent Monitoring pipeline, ITSI AI service, dashboards,
ThousandEyes).

## The map
| Dir | What it is |
|---|---|
| `base-demo/` | Your original repo — **including ~121 working-tree changes made since April** that only existed on Craig's copy (Cora SPA widgets, payment-decline handling, script/ITSI evolution). Diff list: `cluster-snapshot/base-repo-uncommitted-files.txt`. Secrets/state-captures stripped, token values redacted. |
| `DRIFT.md` | **Read second (after this).** Every way live reality diverged from the April repo — incl. the t3→m5 node lesson and the nginx/watchdog fix. |
| top-level `app/ k8s/ collector/ splunk-o11y/ itsi/ thousandeyes/ frontend/` | The AI layer as clean, parameterised build assets (see `README.md` build order). |
| `itsi-export/` | The full live ITSI estate (40 services / 185 KPIs / 37 correlation searches / both glass tables) — restore these rather than rebuilding by hand. |
| `cluster-snapshot/` + `splunk-box/` + `infra/` | Byte-exact live k8s manifests (tokens redacted), the Splunk box's nginx + watchdog files, and the current cluster spec. |
| `harvest/` | Untouched raw exports (reference of record). |
| `docs/` | The annotated Word guide to the agent + Splunk AI-monitoring recipe. |

## Build order for a from-scratch rebuild
1. **Infra** — `base-demo/terraform` + `infra/CLUSTER-SPEC.md`. Two updates to
   your originals: **m5.xlarge, never t3** (burst-credit throttling took the
   demo down), and Kubernetes 1.31.
2. **Splunk box** — your cloud-init, then overlay `splunk-box/` (nginx
   `spa.conf` incl. the port-80 `/__proxy_health` block, watchdog units,
   indexes/HEC stanzas). After any node change, update the node IPs in spa.conf.
3. **Payments demo** — your helm/services/chaos-controller as before; then
   reconcile against `cluster-snapshot/natwest-namespace-live.yaml` for drift.
4. **ITSI** — restore from `itsi-export/` (POST the objects back via
   `itoa_interface`), or rebuild selectively; glass-table skinning notes in
   `itsi/RESKIN-NOTES.md`.
5. **AI layer** — follow `README.md` §0–7. §0 (org flags, LLM connection,
   token-with-`ai_monitoring`-role) is where success is decided.
6. **Customise** — assistant name/bank via env (`CORA_AGENT_NAME`,
   `CORA_BANK_NAME`, `CORA_AGENT_ID`), SPA widget name in one file
   (`frontend/README.md`), glass-table rename/re-skin per the notes.

## Tokens you must supply (none are in this repo)
`config/kit.env.example` lists them all: O11y ingest (INGEST+API scopes **and
the ai_monitoring role** — the #1 trap), O11y API, ThousandEyes bearer + aid,
HEC, Splunk admin, Anthropic key. Anything reading `<<REDACTED-TOKEN>>` in the
exports is a slot for yours.

## When something misbehaves
`DRIFT.md`'s gotcha index first, then the matching section of
`docs/Splunk-AI-Agent-Monitoring-Guide.docx`. Every bullet is a real incident
we debugged, not theory.

Questions → Craig. Enjoy!
