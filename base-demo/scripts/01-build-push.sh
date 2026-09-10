#!/usr/bin/env bash
# Build the demo's container images and push them to ECR. The repos are
# created by Terraform (terraform/main.tf -> aws_ecr_repository.app), so
# this script just looks up the URLs from `terraform output`.
#
# Images built (each one targeted by its own ${*_TAG} env var; default to
# IMAGE_TAG so a single bump of IMAGE_TAG rebuilds the whole stack):
#
#   - natwest-payments-service              -> app/Dockerfile
#   - natwest-payments-traffic-generator    -> traffic-generator/Dockerfile
#   - natwest-payments-ledger-service-java  -> services/ledger-service-java/Dockerfile
#   - natwest-payments-web-frontend         -> frontend/Dockerfile
#   - natwest-payments-chaos-controller     -> chaos-controller/Dockerfile
#
# Skip a target by setting `SKIP_<TARGET>=1` (e.g. SKIP_FRONTEND=1,
# SKIP_CHAOS_CONTROLLER=1).

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_cmd docker aws terraform

REGION=$(tf_output region)
SERVICE_REPO=$(tf_output ecr_service_repo_url)
TRAFFIC_REPO=$(tf_output ecr_traffic_generator_repo_url)
LEDGER_JAVA_REPO=$(tf_output ecr_ledger_service_java_repo_url)
FRONTEND_REPO=$(tf_output ecr_web_frontend_repo_url)
CHAOS_CONTROLLER_REPO=$(tf_output ecr_chaos_controller_repo_url 2>/dev/null || true)
REGISTRY="${SERVICE_REPO%/*}"

SERVICE_TAG="${SERVICE_TAG:-${IMAGE_TAG}}"
TRAFFIC_TAG="${TRAFFIC_TAG:-${IMAGE_TAG}}"
LEDGER_JAVA_TAG="${LEDGER_JAVA_TAG:-${IMAGE_TAG}}"
FRONTEND_TAG="${FRONTEND_TAG:-${IMAGE_TAG}}"
CHAOS_CONTROLLER_TAG="${CHAOS_CONTROLLER_TAG:-${IMAGE_TAG}}"
FRONTEND_DIR="${REPO_ROOT}/frontend"
LEDGER_JAVA_DIR="${REPO_ROOT}/services/ledger-service-java"
CHAOS_CONTROLLER_DIR="${REPO_ROOT}/chaos-controller"

log "ECR login: ${REGISTRY}"
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

if [[ -z "${SKIP_SERVICE:-}" ]]; then
  log "build+push service image ${SERVICE_REPO}:${SERVICE_TAG}"
  docker buildx build \
    --platform linux/amd64 \
    --file "${APP_DIR}/Dockerfile" \
    --tag "${SERVICE_REPO}:${SERVICE_TAG}" \
    --push \
    "${APP_DIR}"
fi

if [[ -z "${SKIP_TRAFFIC:-}" ]]; then
  log "build+push traffic-generator image ${TRAFFIC_REPO}:${TRAFFIC_TAG}"
  docker buildx build \
    --platform linux/amd64 \
    --file "${TRAFFIC_DIR}/Dockerfile" \
    --tag "${TRAFFIC_REPO}:${TRAFFIC_TAG}" \
    --push \
    "${TRAFFIC_DIR}"
fi

if [[ -z "${SKIP_LEDGER_JAVA:-}" && -d "${LEDGER_JAVA_DIR}" ]]; then
  log "build+push ledger-service-java image ${LEDGER_JAVA_REPO}:${LEDGER_JAVA_TAG}"
  docker buildx build \
    --platform linux/amd64 \
    --file "${LEDGER_JAVA_DIR}/Dockerfile" \
    --tag "${LEDGER_JAVA_REPO}:${LEDGER_JAVA_TAG}" \
    --push \
    "${LEDGER_JAVA_DIR}"
fi

if [[ -z "${SKIP_FRONTEND:-}" && -d "${FRONTEND_DIR}" ]]; then
  log "build+push web-frontend image ${FRONTEND_REPO}:${FRONTEND_TAG}"
  docker buildx build \
    --platform linux/amd64 \
    --file "${FRONTEND_DIR}/Dockerfile" \
    --tag "${FRONTEND_REPO}:${FRONTEND_TAG}" \
    --push \
    "${FRONTEND_DIR}"
fi

# Additive: rum-user-simulator (Playwright browser sessions).
# Opt-in via BUILD_RUM_USER_SIMULATOR=1 so pre-existing workflows are unaffected.
# ECR repo `natwest-payments-rum-user-simulator` must exist (aws ecr create-repository).
RUM_USER_SIMULATOR_DIR="${REPO_ROOT}/rum-user-simulator"
if [[ -n "${BUILD_RUM_USER_SIMULATOR:-}" && -d "${RUM_USER_SIMULATOR_DIR}" ]]; then
  RUM_USER_SIMULATOR_REPO="${RUM_USER_SIMULATOR_REPO:-${REGISTRY}/natwest-payments-rum-user-simulator}"
  RUM_USER_SIMULATOR_TAG="${RUM_USER_SIMULATOR_TAG:-${IMAGE_TAG}}"
  log "build+push rum-user-simulator image ${RUM_USER_SIMULATOR_REPO}:${RUM_USER_SIMULATOR_TAG}"
  docker buildx build \
    --platform linux/amd64 \
    --file "${RUM_USER_SIMULATOR_DIR}/Dockerfile" \
    --tag "${RUM_USER_SIMULATOR_REPO}:${RUM_USER_SIMULATOR_TAG}" \
    --push \
    "${RUM_USER_SIMULATOR_DIR}"
  echo "  rum-user-simulator image: ${RUM_USER_SIMULATOR_REPO}:${RUM_USER_SIMULATOR_TAG}"
fi

if [[ -z "${SKIP_CHAOS_CONTROLLER:-}" && -d "${CHAOS_CONTROLLER_DIR}" ]]; then
  if [[ -z "${CHAOS_CONTROLLER_REPO}" || "${CHAOS_CONTROLLER_REPO}" == "null" ]]; then
    warn "ecr_chaos_controller_repo_url terraform output missing - run 'terraform apply' first; skipping chaos-controller image"
  else
    log "build+push chaos-controller image ${CHAOS_CONTROLLER_REPO}:${CHAOS_CONTROLLER_TAG}"
    docker buildx build \
      --platform linux/amd64 \
      --file "${CHAOS_CONTROLLER_DIR}/Dockerfile" \
      --tag "${CHAOS_CONTROLLER_REPO}:${CHAOS_CONTROLLER_TAG}" \
      --push \
      "${CHAOS_CONTROLLER_DIR}"
  fi
fi

log "done:"
echo "  service image:           ${SERVICE_REPO}:${SERVICE_TAG}"
echo "  traffic image:           ${TRAFFIC_REPO}:${TRAFFIC_TAG}"
echo "  ledger-java image:       ${LEDGER_JAVA_REPO}:${LEDGER_JAVA_TAG}"
echo "  web-frontend image:      ${FRONTEND_REPO}:${FRONTEND_TAG}"
if [[ -n "${CHAOS_CONTROLLER_REPO}" && "${CHAOS_CONTROLLER_REPO}" != "null" ]]; then
  echo "  chaos-controller image:  ${CHAOS_CONTROLLER_REPO}:${CHAOS_CONTROLLER_TAG}"
fi
