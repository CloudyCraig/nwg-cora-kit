#!/usr/bin/env bash
# Provision the EKS cluster, VPC, ECR and secrets via Terraform, then mint
# the Postgres-monitoring credential the collector and chart share.
#
# Required env:
#   TF_VAR_allowed_public_api_cidrs  - JSON list of CIDRs allowed to reach EKS API
#   TF_VAR_splunk_realm              - e.g. us1, eu0
#   TF_VAR_splunk_access_token       - Splunk Observability ingest token
# Optional:
#   TF_VAR_region       default eu-west-2
#   TF_VAR_cluster_name default natwest-payments-demo
#   PG_EXPORTER_PASSWORD  pre-existing password to reuse (otherwise generated)
#
# Side effects (beyond terraform):
#   * Creates k8s namespaces `natwest` and `splunk-otel` if missing
#   * Generates a Postgres `payments_exporter` password (32 hex chars) and writes
#     it into:
#       - .env (PG_EXPORTER_PASSWORD=...) so subsequent helm calls pick it up
#       - Secret `postgres-monitoring` in BOTH namespaces (the chart reads it
#         via stringData, the collector via extraEnvVars+secretKeyRef)
#   * Re-runs are idempotent - if the secret already exists with the same
#     password we leave it alone, otherwise we patch it.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_cmd terraform aws kubectl openssl

: "${TF_VAR_allowed_public_api_cidrs:?Set TF_VAR_allowed_public_api_cidrs to a JSON list like '[\"1.2.3.4/32\"]'}"
: "${TF_VAR_splunk_realm:?Set TF_VAR_splunk_realm (e.g. us1)}"
: "${TF_VAR_splunk_access_token:?Set TF_VAR_splunk_access_token}"

log "terraform init"
terraform -chdir="${TERRAFORM_DIR}" init -upgrade

log "terraform apply (this takes ~15-20 minutes for EKS)"
terraform -chdir="${TERRAFORM_DIR}" apply -auto-approve

CLUSTER_NAME=$(tf_output cluster_name)
REGION=$(tf_output region)

log "updating kubeconfig: aws eks update-kubeconfig --region ${REGION} --name ${CLUSTER_NAME}"
aws eks update-kubeconfig --region "${REGION}" --name "${CLUSTER_NAME}" >/dev/null

log "cluster reachable:"
kubectl get nodes

# ---------------------------------------------------------------------------
# Postgres monitoring credential
#
# Both the natwest chart (postgres_exporter sidecar) and the splunk-otel
# collector (postgresql receiver) need to know the same password. We mint
# it here once and replicate the resulting Secret into both namespaces.
# ---------------------------------------------------------------------------
PG_MON_USER="${PG_EXPORTER_USER:-payments_exporter}"
if [[ -z "${PG_EXPORTER_PASSWORD:-}" ]]; then
  PG_EXPORTER_PASSWORD="$(openssl rand -hex 16)"
  log "generated postgres-monitoring password (length=32)"
else
  log "reusing PG_EXPORTER_PASSWORD from environment"
fi

# Persist into .env so 03-deploy / collector helm-upgrade pick it up on
# subsequent invocations without us having to plumb it through env vars
# every time. Idempotent: any prior PG_EXPORTER_PASSWORD line is replaced.
ENV_FILE="${REPO_ROOT}/.env"
touch "${ENV_FILE}"
# strip any existing assignments (avoids duplicates after re-runs)
grep -v -E '^(PG_EXPORTER_USER|PG_EXPORTER_PASSWORD)=' "${ENV_FILE}" > "${ENV_FILE}.tmp" || true
{
  printf 'PG_EXPORTER_USER=%s\n' "${PG_MON_USER}"
  printf 'PG_EXPORTER_PASSWORD=%s\n' "${PG_EXPORTER_PASSWORD}"
} >> "${ENV_FILE}.tmp"
mv "${ENV_FILE}.tmp" "${ENV_FILE}"
chmod 600 "${ENV_FILE}"

# Make sure both namespaces exist before we drop the Secret into them.
for ns in "${SERVICE_NAMESPACE}" "${COLLECTOR_NAMESPACE}"; do
  if ! kubectl get ns "${ns}" >/dev/null 2>&1; then
    log "creating namespace ${ns}"
    kubectl create namespace "${ns}" >/dev/null
  fi
done

# kubectl create secret with --dry-run=client | apply -f - is the standard
# idempotent pattern for replicating opaque secrets across namespaces.
for ns in "${SERVICE_NAMESPACE}" "${COLLECTOR_NAMESPACE}"; do
  log "upserting Secret/postgres-monitoring in namespace ${ns}"
  kubectl create secret generic postgres-monitoring \
    --namespace="${ns}" \
    --from-literal=PG_EXPORTER_USER="${PG_MON_USER}" \
    --from-literal=PG_EXPORTER_PASSWORD="${PG_EXPORTER_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done

# Re-export so any downstream `--set` invocations in the same shell pick it up.
export PG_EXPORTER_USER="${PG_MON_USER}"
export PG_EXPORTER_PASSWORD

# ---------------------------------------------------------------------------
# Audit pepper for HMAC tokenizing customer ids before they enter the
# nwpay_audit Splunk index. Same pattern as the postgres password:
# generated once on first apply, persisted to .env so subsequent helm
# upgrades reuse the same value (rotating the pepper invalidates
# historical correlations - acceptable for a demo, surfaced loudly).
# ---------------------------------------------------------------------------
if [[ -z "${NWPAY_AUDIT_PEPPER:-}" ]]; then
  NWPAY_AUDIT_PEPPER="$(openssl rand -hex 32)"
  log "generated nwpay-audit-pepper (length=64)"
else
  log "reusing NWPAY_AUDIT_PEPPER from environment"
fi

grep -v -E '^NWPAY_AUDIT_PEPPER=' "${ENV_FILE}" > "${ENV_FILE}.tmp" || true
printf 'NWPAY_AUDIT_PEPPER=%s\n' "${NWPAY_AUDIT_PEPPER}" >> "${ENV_FILE}.tmp"
mv "${ENV_FILE}.tmp" "${ENV_FILE}"
chmod 600 "${ENV_FILE}"

# Drop the pepper into the natwest namespace as a Secret. The chart's
# deployment template mounts it at /etc/nwpay-audit-pepper/pepper read-only
# on services that opt in via auditEnabled: true.
log "upserting Secret/nwpay-audit-pepper in namespace ${SERVICE_NAMESPACE}"
kubectl create secret generic nwpay-audit-pepper \
  --namespace="${SERVICE_NAMESPACE}" \
  --from-literal=pepper="${NWPAY_AUDIT_PEPPER}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
export NWPAY_AUDIT_PEPPER

log "done. ECR service repo: $(tf_output ecr_service_repo_url)"
log "Postgres monitoring user: ${PG_MON_USER} (password persisted in .env)"
log "Pass to helm install:  --set infrastructure.postgres.monitoringUser.password=\$PG_EXPORTER_PASSWORD"
