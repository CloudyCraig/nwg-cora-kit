#!/usr/bin/env bash
# rum-user-simulator rollback — one-command removal.
#
# Idempotent. Runs the following steps, each ignoring "already gone" errors:
#
#   1. helm upgrade with rumUserSimulator.enabled=false   (chart-level remove)
#   2. kubectl delete deploy rum-user-simulator           (belt-and-braces)
#   3. (optional) delete the ECR repo tag we pushed        (space reclaim)
#   4. (optional) delete the ECR repo itself               (full nuke)
#
# The values.yaml `rumUserSimulator:` block and the rum-user-simulator/
# directory are LEFT IN PLACE by this script — that's file-editing state
# in the user's tree. Delete the block by hand or with your editor.
#
# Usage:
#   ./rollback.sh                    # helm + kubectl steps only
#   ./rollback.sh --delete-tag       # also delete the specific ECR image tag
#   ./rollback.sh --delete-repo      # also delete the ECR repo (destructive)
#   NAMESPACE=natwest KUBE_CONTEXT=natwest ./rollback.sh
#
# Env vars (all optional):
#   KUBE_CONTEXT       default: natwest
#   NAMESPACE          default: natwest
#   HELM_RELEASE       default: natwest-payments
#   CHART_DIR          default: ../helm/natwest-payments (relative to this script)
#   ECR_REPO_NAME      default: natwest-payments-rum-user-simulator
#   ECR_REGION         default: eu-west-2
#   AWS_PROFILE        default: natwest
#   IMAGE_TAG          default: 0.1.0

set -Eeuo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-natwest}"
NAMESPACE="${NAMESPACE:-natwest}"
HELM_RELEASE="${HELM_RELEASE:-natwest-payments}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHART_DIR="${CHART_DIR:-${SCRIPT_DIR}/../helm/natwest-payments}"
ECR_REPO_NAME="${ECR_REPO_NAME:-natwest-payments-rum-user-simulator}"
ECR_REGION="${ECR_REGION:-eu-west-2}"
AWS_PROFILE="${AWS_PROFILE:-natwest}"
IMAGE_TAG="${IMAGE_TAG:-0.1.0}"

DELETE_TAG=0
DELETE_REPO=0
for arg in "$@"; do
  case "$arg" in
    --delete-tag) DELETE_TAG=1 ;;
    --delete-repo) DELETE_REPO=1 ;;
    -h|--help)
      grep -E '^# ' "$0" | sed 's/^# //'
      exit 0
      ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '[rollback] %s\n' "$*" >&2; }

log "helm upgrade → rumUserSimulator.enabled=false (release=${HELM_RELEASE})"
if helm --kube-context "${KUBE_CONTEXT}" -n "${NAMESPACE}" list -q \
     | grep -qx "${HELM_RELEASE}"; then
  helm --kube-context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
    upgrade "${HELM_RELEASE}" "${CHART_DIR}" \
    --reuse-values \
    --set rumUserSimulator.enabled=false \
    --wait --timeout 3m \
  || log "helm upgrade returned non-zero (continuing to manual delete)"
else
  log "helm release ${HELM_RELEASE} not found — skipping"
fi

log "kubectl delete deploy/rum-user-simulator (idempotent)"
kubectl --context "${KUBE_CONTEXT}" -n "${NAMESPACE}" \
  delete deploy rum-user-simulator --ignore-not-found=true

if [[ "${DELETE_TAG}" -eq 1 ]]; then
  log "ECR: deleting image tag ${ECR_REPO_NAME}:${IMAGE_TAG}"
  aws --profile "${AWS_PROFILE}" --region "${ECR_REGION}" ecr batch-delete-image \
    --repository-name "${ECR_REPO_NAME}" \
    --image-ids imageTag="${IMAGE_TAG}" >/dev/null \
  || log "ECR image tag ${IMAGE_TAG} not found — skipping"
fi

if [[ "${DELETE_REPO}" -eq 1 ]]; then
  log "ECR: deleting repo ${ECR_REPO_NAME} (destructive)"
  aws --profile "${AWS_PROFILE}" --region "${ECR_REGION}" ecr delete-repository \
    --repository-name "${ECR_REPO_NAME}" --force >/dev/null \
  || log "ECR repo ${ECR_REPO_NAME} not found — skipping"
fi

log "done. Verify:"
log "  kubectl --context ${KUBE_CONTEXT} -n ${NAMESPACE} get deploy rum-user-simulator"
log "  (expected: NotFound)"
