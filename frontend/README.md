# Frontend (SPA) pieces

Source of truth: Marc's card-payment-demo repo, `frontend/` — the kit does not
duplicate it. The AI-assistant additions are:

- `src/components/CoraChat.tsx` — the floating "Ask Cora" widget.
  DISPLAY NAME: greeting text, panel title, launcher label, avatar letter all
  live here; rename in this one file.
- `src/components/CoraTrafficCard.tsx` — presenter STREAMING/OFF toggle on the
  Ops page (drives /cora/api/traffic-config; state survives reloads, resets on
  agent pod restart).
- `src/pages/SendMoney.tsx` + `src/rum.ts` — payment decline/degraded RUM
  reporting (predates the AI work but part of the demo story).
- `nginx/default.conf.template` — `/cora/api/` same-origin proxy block
  (60s read timeout for LLM latency).
- `nginx/docker-entrypoint.sh` — CORA_BACKEND_HOST/PORT defaults.
  GOTCHA: the vars are CORA_BACKEND_* (NOT CORA_AGENT_*) because Kubernetes
  injects docker-link style CORA_AGENT_PORT=tcp://... for the cora-agent
  Service, which clobbers anything of that name.
- `src/styles.css` — `.cora-*` and `.cora-traffic__*` blocks.

Build & deploy pattern (from the repo root):
  docker buildx build --platform linux/amd64 \
    -t <ecr>/web-frontend:<version> --push frontend/
  kubectl -n natwest set image deploy/web-frontend web-frontend=<ecr>/web-frontend:<version>
Keep the previous tag noted for instant rollback.
