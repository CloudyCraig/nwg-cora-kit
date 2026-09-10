#!/usr/bin/env bash
# Enable + deploy the chaos-controller microservice on top of an
# already-running natwest Helm release. Run after scripts/05-deploy-
# frontend.sh so the web-frontend exists (the SPA pulls the presenter
# token from /config.js, which the chart renders from the same Secret
# this script creates).
#
# Required:
#   * `terraform apply` has emitted `ecr_chaos_controller_repo_url` (run
#     scripts/00-provision.sh after the new ECR repo was added in
#     terraform/main.tf).
#   * `scripts/01-build-push.sh` has pushed the chaos-controller image.
#
# Optional env:
#   CHAOS_CONTROLLER_TAG    - image tag (default: ${IMAGE_TAG})
#   CHAOS_PRESENTER_TOKEN   - shared bearer used by the SPA. If unset
#                             we generate `openssl rand -hex 24` and
#                             print it so the operator can bookmark it.
#                             Set in .env to keep a stable value across
#                             redeploys.
#   SPLUNK_HEC_ENDPOINT_OVERRIDE / SPLUNK_HEC_TOKEN_OVERRIDE - pin the
#                             HEC config (default: read terraform
#                             outputs splunk_enterprise_hec_endpoint_public
#                             and splunk_enterprise_hec_token_scripts).
#
# Idempotent: subsequent runs re-apply the chart without rolling the
# rest of the release because we --reuse-values + --set only the
# chaosController.* keys.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_cmd helm kubectl terraform

CHAOS_CONTROLLER_REPO=$(tf_output ecr_chaos_controller_repo_url)
if [[ -z "${CHAOS_CONTROLLER_REPO}" || "${CHAOS_CONTROLLER_REPO}" == "null" ]]; then
  fail "terraform output ecr_chaos_controller_repo_url is empty. Run 'terraform apply' first."
fi
CHAOS_CONTROLLER_TAG="${CHAOS_CONTROLLER_TAG:-${IMAGE_TAG}}"

# Generate a presenter token if one isn't pinned in the environment.
# We never echo the token to logs unless we just generated it (and the
# operator needs to copy it). Pinned tokens are masked.
if [[ -z "${CHAOS_PRESENTER_TOKEN:-}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    CHAOS_PRESENTER_TOKEN="$(openssl rand -hex 24)"
  else
    CHAOS_PRESENTER_TOKEN="$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 48)"
  fi
  TOKEN_PROVENANCE="generated"
else
  TOKEN_PROVENANCE="provided"
fi

# HEC endpoint + token for the chaos-controller's audit emitter. Falls
# back to the public HEC endpoint / scripts token from terraform
# outputs - same source scripts/incident.sh uses, so audit events from
# the dashboard land in the SAME index with the SAME shape.
HEC_ENDPOINT="${SPLUNK_HEC_ENDPOINT_OVERRIDE:-$(terraform -chdir="${TERRAFORM_DIR}" output -raw splunk_enterprise_hec_endpoint_public 2>/dev/null || true)}"
HEC_TOKEN="${SPLUNK_HEC_TOKEN_OVERRIDE:-$(terraform -chdir="${TERRAFORM_DIR}" output -raw splunk_enterprise_hec_token_scripts 2>/dev/null || true)}"
if [[ "${HEC_ENDPOINT}" == "null" ]]; then HEC_ENDPOINT=""; fi
if [[ "${HEC_TOKEN}" == "null" ]]; then HEC_TOKEN=""; fi

if [[ -z "${HEC_ENDPOINT}" || -z "${HEC_TOKEN}" ]]; then
  warn "HEC endpoint/token unresolved; chaos audit events will be dropped (controller still works). Set splunk_enterprise_enabled=true in terraform.tfvars to enable."
fi

log "helm upgrade --reuse-values chaosController.enabled=true (image=${CHAOS_CONTROLLER_REPO}:${CHAOS_CONTROLLER_TAG}, token=${TOKEN_PROVENANCE})"
helm upgrade natwest-payments "${HELM_CHART_DIR}" \
  --namespace "${SERVICE_NAMESPACE}" \
  --reuse-values \
  --set "chaosController.enabled=true" \
  --set "chaosController.image.repository=${CHAOS_CONTROLLER_REPO}" \
  --set "chaosController.image.tag=${CHAOS_CONTROLLER_TAG}" \
  --set "chaosController.presenterToken=${CHAOS_PRESENTER_TOKEN}" \
  --set "chaosController.hec.endpoint=${HEC_ENDPOINT}" \
  --set "chaosController.hec.token=${HEC_TOKEN}" \
  --wait --timeout 5m

# Roll the web-frontend so the new /config.js contains the chaosToken
# and the nginx /chaos/api/ proxy points at the new upstream. We use
# kubectl rollout restart rather than helm to avoid touching anything
# else.
log "rolling web-frontend deployment to pick up the new chaos token"
kubectl -n "${SERVICE_NAMESPACE}" rollout restart deploy/web-frontend
kubectl -n "${SERVICE_NAMESPACE}" rollout status deploy/web-frontend --timeout=180s

log "chaos-controller deployed."
echo
echo "  Dashboard URL:"
PUBLIC_SPA_URL="$(terraform -chdir="${TERRAFORM_DIR}" output -raw public_spa_url 2>/dev/null || true)"
if [[ -n "${PUBLIC_SPA_URL}" && "${PUBLIC_SPA_URL}" != "null" ]]; then
  printf '    %s/?ops=1#/ops\n' "${PUBLIC_SPA_URL%/}"
else
  printf '    <SPA URL>/?ops=1#/ops   (run scripts/05a-frontend-portforward.sh for localhost)\n'
fi
echo
if [[ "${TOKEN_PROVENANCE}" == "generated" ]]; then
  echo "  Presenter token (copy to .env to keep stable across redeploys):"
  echo "    CHAOS_PRESENTER_TOKEN=${CHAOS_PRESENTER_TOKEN}"
else
  echo "  Presenter token: <provided via env, not echoed>"
fi
echo
echo "  Recover everything:    make chaos-recover"
echo "  Catalog (no mutation): curl -s -H \"X-Chaos-Token: <token>\" <spa>/chaos/api/scenarios | jq ."
