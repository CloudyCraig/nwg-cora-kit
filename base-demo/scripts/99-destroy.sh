#!/usr/bin/env bash
# Tear everything down. Safe to re-run.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_cmd kubectl helm terraform

log "uninstalling traffic-generator (if present)"
kubectl -n "${SERVICE_NAMESPACE}" delete deploy traffic-generator --ignore-not-found

log "uninstalling natwest-payments helm release (if present)"
helm uninstall natwest-payments -n "${SERVICE_NAMESPACE}" 2>/dev/null || true
kubectl delete namespace "${SERVICE_NAMESPACE}" --ignore-not-found

log "uninstalling splunk-otel-collector helm release (if present)"
helm uninstall splunk-otel-collector -n "${COLLECTOR_NAMESPACE}" 2>/dev/null || true
kubectl delete namespace "${COLLECTOR_NAMESPACE}" --ignore-not-found

log "terraform destroy (EKS + VPC + ECR + Secrets)"
terraform -chdir="${TERRAFORM_DIR}" destroy -auto-approve

log "done."
