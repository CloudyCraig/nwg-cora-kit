#!/usr/bin/env bash
# Repair Splunk APM service-map wiring after chaos demos or drift.
#
# Preferred path (chaos-controller >= apm-topology-repair scenario):
#   POST /chaos/api/apm-topology-repair/clear
#   POST /chaos/api/recover   (now ends with topology repair)
#
# Fallback: POST /chaos/api/recover only.
#
# Usage:
#   scripts/08-repair-apm-topology.sh
#   CHAOS_PRESENTER_TOKEN=... scripts/08-repair-apm-topology.sh

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_cmd curl python3

SPA_URL="${SPA_URL:-$(terraform -chdir="${TERRAFORM_DIR}" output -raw public_spa_url 2>/dev/null || true)}"
TOKEN="${CHAOS_PRESENTER_TOKEN:-}"
if [[ -z "${TOKEN}" && -n "${SPA_URL}" && "${SPA_URL}" != "null" ]]; then
  if command -v kubectl >/dev/null 2>&1; then
    TOKEN="$(kubectl -n "${SERVICE_NAMESPACE}" get secret chaos-controller-token \
      -o jsonpath='{.data.CHAOS_PRESENTER_TOKEN}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  fi
fi

if [[ -z "${SPA_URL}" || "${SPA_URL}" == "null" || -z "${TOKEN}" ]]; then
  fail "need SPA_URL and CHAOS_PRESENTER_TOKEN (or a deployed chaos-controller secret)"
fi

SPA_URL="${SPA_URL%/}"
AUTH=(-H "X-Chaos-Token: ${TOKEN}" -H "Content-Type: application/json")

log "clearing all chaos scenarios + repairing APM topology"
curl -fsS -X POST "${AUTH[@]}" -d '{}' "${SPA_URL}/chaos/api/recover" | head -c 4000
echo

log "explicit topology repair (no-op if controller predates apm-topology-repair)"
if curl -fsS -X POST "${AUTH[@]}" -d '{}' \
  "${SPA_URL}/chaos/api/apm-topology-repair/clear" 2>/dev/null | head -c 2000; then
  echo
else
  warn "apm-topology-repair scenario not on controller yet - run: make chaos-deploy"
fi

if command -v kubectl >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/apm_topology_repair.sh"
  apm_topology_repair
else
  warn "kubectl not available - skipped shell topology repair"
fi

log "waiting 90s for rollouts and trace windows"
sleep 90

log "verifying topology in Splunk"
python3 "${SCRIPT_DIR}/lib/verify_apm_topology.py" \
  --host "${SPLUNK_ENTERPRISE_HOST:-itsi.splunk-observability.com}" \
  --password "${TF_VAR_splunk_enterprise_admin_password:-smartway}"
