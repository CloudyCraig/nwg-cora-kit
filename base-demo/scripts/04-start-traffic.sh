#!/usr/bin/env bash
# Start the traffic generator Deployment that drives api-gateway.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_cmd kubectl terraform

TRAFFIC_REPO=$(tf_output ecr_traffic_generator_repo_url)
IMAGE_REF="${TRAFFIC_REPO}:${IMAGE_TAG}"

TMP_MANIFEST=$(mktemp)
trap 'rm -f "${TMP_MANIFEST}"' EXIT
sed "s|__TRAFFIC_GENERATOR_IMAGE__|${IMAGE_REF}|" \
    "${TRAFFIC_DIR}/deployment.yaml" > "${TMP_MANIFEST}"

log "deploying traffic-generator with image ${IMAGE_REF}"
kubectl apply -f "${TMP_MANIFEST}"
kubectl -n "${SERVICE_NAMESPACE}" rollout restart deploy/traffic-generator
kubectl -n "${SERVICE_NAMESPACE}" rollout status deploy/traffic-generator --timeout=3m

log "tail logs with:  kubectl -n ${SERVICE_NAMESPACE} logs deploy/traffic-generator -f"
