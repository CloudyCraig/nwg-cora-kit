# NWG Demo Kit — full rebuild (payments demo + Cora AI-agent layer)

Everything needed to rebuild the **entire NatWest payments demo from bare
AWS** — cluster, microservices, chaos controller, traffic generator, SPA,
Splunk box — **plus the AI-assistant layer**: the Cora agent (Flask +
Anthropic), its OpenTelemetry pipeline into Splunk **AI Agent Monitoring**,
the SPA widgets, the ITSI "AI agents" service + glass tables, the O11y
dashboard, and the ThousandEyes synthetics. Harvested 2026-09-10 from the
live environment.

**New here? Read `START-HERE-MARC.md` first** — it maps the whole repo and
gives the from-scratch build order:

| Piece | Where |
|---|---|
| Original demo (terraform + cloud-init, helm, services, chaos controller, traffic gen, SPA) | `base-demo/` (incl. all post-April working-tree changes) |
| What changed since April (nodes, nginx/watchdog, ITSI, TE, …) | `DRIFT.md` + `infra/CLUSTER-SPEC.md` |
| Live-state exports (ITSI estate, k8s manifests, Splunk-box config) | `itsi-export/`, `cluster-snapshot/`, `splunk-box/` |
| **AI layer build (the rest of THIS file)** | `app/ k8s/ collector/ frontend/ splunk-o11y/ itsi/ thousandeyes/` |

> Companion reading: `docs/Splunk-AI-Agent-Monitoring-Guide.docx` — the full
> annotated walkthrough of the agent code and the AI-monitoring recipe.
> `harvest/` holds byte-exact copies of everything as it ran in production;
> the top-level dirs hold the cleaned, parameterised build assets.

## Customisation (all in `config/kit.env`)

| What | Variable | Notes |
|---|---|---|
| Assistant name | `CORA_AGENT_NAME` | Flows into spans (`gen_ai.agent.name`), the AI Agents row, the system prompt |
| Agent id | `CORA_AGENT_ID` | Stable id in `gen_ai.agent.id` |
| Bank name | `CORA_BANK_NAME` | System prompt |
| Model | `CORA_MODEL` / `LLM_CONNECTION_MODEL` | API alias vs **exact dated id** for the Splunk LLM connection |
| All tokens | see file | O11y ingest/API, TE bearer, HEC, Splunk admin, Anthropic |

Frontend display name and the ITSI glass-table skin are customised in their
own steps below (§4, §6).

## Build order

**0. Prerequisites — Observability Cloud org** (`splunk-o11y/ORG-PREREQS.md`):
org-scope feature flags (`apm2AIOnOlly`, `apm2AIOnOllyGA`, `apm2AIOnOllyPart2`,
`openAiIntegration`; `dbMonitoring` for the DB panel), an **LLM Providers
connection** (Anthropic + the *dated* model id), and the ingest token created
with **INGEST + API scopes AND the `ai_monitoring` role** — the UI hides roles
unless "API token with roles" is ticked, and a role-less token's spans never
reach the AI trace store.

**1. Secrets** (values by hand, never in manifests):
```sh
kubectl -n $K8S_NAMESPACE create secret generic cora-anthropic --from-literal=ANTHROPIC_API_KEY=<key>
kubectl -n $K8S_NAMESPACE create secret generic cora-neworg    --from-literal=SPLUNK_ACCESS_TOKEN=<ingest+ai_monitoring token>
# chaos-controller-token: HEC endpoint/token/index + presenter token (see k8s yaml for keys)
```

**2. Agent + collector + loadgen** (`app/`, `collector/`, `k8s/`):
```sh
kubectl -n $K8S_NAMESPACE create configmap cora-agent-code \
  --from-file=app.py=app/app.py --from-file=requirements.txt=app/requirements.txt \
  --from-file=entrypoint.sh=app/entrypoint.sh
kubectl -n $K8S_NAMESPACE create configmap cora-otelcol-config --from-file=config.yaml=collector/otelcol-config.yaml
kubectl -n $K8S_NAMESPACE create configmap cora-loadgen-code --from-file=loadgen.py=app/loadgen.py
kubectl -n $K8S_NAMESPACE apply -f k8s/
```
Set `SPLUNK_REALM` + the `CORA_*` customisation env on the deployments.
**Gotchas baked into the design — don't undo them:**
- traces flow app → cora-otelcol → O11y ingest with the AI token (single path,
  no node-collector duplicate);
- `send_otlp_histograms: true` must be live **before the agent's first
  emission** — a cumulative/legacy series on the standard `gen_ai.*` names
  poisons them org-wide and only Splunk can clean it;
- `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta` and
  `OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=true` are load-bearing
  (no content ⇒ spans never classify as agent interactions);
- after editing a configmap, wait ~80 s before `rollout restart` (kubelet sync);
- the HEC endpoint is bare `host:port` — the code appends `/services/collector/event`;
- the loadgen's background traffic **defaults OFF** and resets OFF on every
  agent restart (`CORA_TRAFFIC_DEFAULT`); presenters switch it on from the
  Ops page (costs real Anthropic calls when on).

**3. Verify agent registration** — within ~10 min of first traffic the agent
name appears in AI Agent Monitoring → Agents; probe from the CLI with
SignalFlow `histogram('gen_ai.agent.duration').count()`.

**4. Frontend widgets** (`frontend/README.md`) — the "Ask <name>" chat widget,
the traffic-toggle card, and the nginx `/cora/api/` proxy; includes where the
display name lives and the image build/rollback pattern.

**5. O11y dashboard** — `cd splunk-o11y && python3 create_dashboard.py`
(recreates the group + 7 charts, renaming Cora → your agent name).

**6. ITSI** — `cd itsi && ./create_ai_agents_service.sh <root-service-key>`
(service + 3 KPIs + entity type/entity with O11y drilldowns). KPI windows are
**5-minute sums** — thresholds in the script are calibrated for baseline ~2
requests/min; scale them with your loadgen rate. The exec glass table ships as
`itsi/glass_table_craigs_executive_view_v3.json`: POST it to
`itoa_interface/glass_table`, then reskin freely — title/logo live in the
`md_003` / `img_002` visualizations, tile colours in each viz's
`majorColorEditorConfig`/`cfg*` blocks, and the top-row trend semantics are
documented in the caption (`md_trendnote`). See `itsi/RESKIN-NOTES.md`.

**7. ThousandEyes** — `cd thousandeyes && python3 create_tests.py --dry-run`,
then without the flag. Targets **must be https** (http → 301 → permanent test
failure), and enable the Splunk O11y stream integration on each test.

## What is NOT in this kit
Only secrets: every token/key is supplied by you via `config/kit.env` (see
the example file) — exports mark their slots with `<<REDACTED-TOKEN>>`.
(`HARVEST-TODO.md` is fully discharged — kept for the record.)
