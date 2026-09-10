#!/usr/bin/env bash
# Reach the web-frontend SPA in environments where the AWS Org SCP denies
# elasticloadbalancing:CreateLoadBalancer (so the Service stays ClusterIP /
# NodePort). Forwards localhost:8080 to the in-cluster Service and prints the
# URL the presenter should open.
#
# This is purely local - the RUM SDK still talks to Splunk Observability via
# the public ingest endpoint (https://rum-ingest.<realm>.signalfx.com), so
# browser RUM events flow even with port-forward.
#
# Behaviour:
#   * Default (no flags): blocks in the foreground and *auto-reconnects* if
#     the underlying pod is rolled (helm upgrade, eviction, OOM, node
#     replacement). kubectl port-forward exits when its pod connection dies;
#     we wait for a fresh Ready pod and reconnect within ~1s.
#   * --health: probe the local listener once and exit (0=healthy, 1=down).
#     Suitable for a launchd KeepAlive or `watch curl` smoke check.
#
# Optional env vars:
#   LOCAL_PORT  - host port to bind (default 8080)
#   NS          - namespace (default natwest)

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_cmd kubectl

LOCAL_PORT="${LOCAL_PORT:-8080}"
NS="${NS:-${SERVICE_NAMESPACE}}"

# --- health mode: one-shot probe, used by launchd / smoke tests --------------
if [[ "${1:-}" == "--health" ]]; then
  require_cmd curl
  url="http://localhost:${LOCAL_PORT}/"
  if curl -sS -m 3 -o /dev/null -w '' "${url}"; then
    log "health: ${url} reachable"
    exit 0
  else
    log "health: ${url} unreachable"
    exit 1
  fi
fi

if ! kubectl -n "${NS}" get svc web-frontend >/dev/null 2>&1; then
  fail "Service web-frontend not found in namespace ${NS}. Run scripts/05-deploy-frontend.sh first."
fi

# Trap Ctrl+C / SIGTERM cleanly so an orphan kubectl child doesn't survive
# this wrapper. The wait below in the loop returns the child's exit code,
# but a SIGINT against the wrapper would otherwise leak the kubectl PID
# until shell logout.
KUBECTL_PID=""
shutdown() {
  log "shutdown requested - stopping port-forward"
  if [[ -n "${KUBECTL_PID}" ]] && kill -0 "${KUBECTL_PID}" 2>/dev/null; then
    kill -TERM "${KUBECTL_PID}" 2>/dev/null || true
    wait "${KUBECTL_PID}" 2>/dev/null || true
  fi
  exit 0
}
trap shutdown INT TERM

log "auto-reconnect mode: forwarding http://localhost:${LOCAL_PORT}/ -> svc/web-frontend:80 (Ctrl+C to stop)"
log "this URL drives RUM traffic into Splunk Observability"

# --- supervised reconnect loop ----------------------------------------------
# Why we need this: kubectl port-forward binds the host listener to the *pod*
# IP, not the Service. When the backing pod is replaced (e.g. helm upgrade
# rolls it, or the node it runs on is recycled), the local listener stays up
# but starts returning empty replies / HTTP 000. The loop re-binds against
# the current Ready pod each iteration so the demo presenter never has to
# notice the churn.
attempt=0
while true; do
  attempt=$((attempt + 1))
  # Wait until at least one web-frontend pod is in Ready state. Long timeout
  # is fine - we'd rather sit here patiently during a rollout than tight-loop
  # and spam Splunk APM with reconnect spans. The trailing `|| {}` swallows
  # the wait failure (e.g. no matching pod yet) and retries every 5s rather
  # than aborting the wrapper.
  if ! kubectl -n "${NS}" wait --for=condition=ready pod \
        -l app.kubernetes.io/name=web-frontend --timeout=120s >/dev/null 2>&1; then
    log "no Ready web-frontend pod yet (attempt ${attempt}); retrying in 5s"
    sleep 5
    continue
  fi

  log "[attempt ${attempt}] kubectl port-forward starting"
  # Backgrounded so the trap can kill it on SIGINT/SIGTERM. We `wait` on
  # the child to bubble up its exit code (kubectl returns non-zero when the
  # underlying pod connection dies, which is our reconnect trigger).
  kubectl -n "${NS}" port-forward svc/web-frontend "${LOCAL_PORT}:80" &
  KUBECTL_PID=$!
  set +e
  wait "${KUBECTL_PID}"
  rc=$?
  set -e
  KUBECTL_PID=""
  log "port-forward exited (rc=${rc}); reconnecting in 1s"
  sleep 1
done
