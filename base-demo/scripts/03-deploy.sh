#!/usr/bin/env bash
# Deploy the 24-service NatWest Payments topology via Helm.
#
# Image tags:
#   IMAGE_TAG          - default Python service image tag (used by every
#                        Python service unless overridden below)
#   LEDGER_JAVA_TAG    - tag for the polyglot Java ledger-service image
#                        (defaults to IMAGE_TAG)

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_cmd kubectl helm terraform

SERVICE_REPO=$(tf_output ecr_service_repo_url)
LEDGER_JAVA_REPO=$(tf_output ecr_ledger_service_java_repo_url)
# Decoupled from IMAGE_TAG on purpose: the Java ledger image versions
# independently of the Python stack, and the db-slow demo REQUIRES >= 0.1.7
# (real pg_sleep + HikariCP exhaustion). Defaulting to IMAGE_TAG (0.1.0)
# silently reverted the cluster to the pre-pg_sleep 0.1.x build over a
# weekend redeploy and broke the demo. Pin the known-good pg_sleep build;
# override with LEDGER_JAVA_TAG=<newer> only after rebuilding pg_sleep.
LEDGER_JAVA_TAG="${LEDGER_JAVA_TAG:-0.1.7}"

# Decoupled from IMAGE_TAG for the same weekend-revert reason as the ledger pin
# above. The Python service image >= 0.1.7 carries the outbound HTTP
# connection-pool fix (requests.Session mounts an HTTPAdapter with
# pool_maxsize=64; tunable via HTTP_POOL_MAXSIZE). Without it the default
# urllib3 pool of 10 overflows under fan-out load, churning connections into
# multi-second tail latency and 6 s read timeouts on customer-profile-service -
# a permanently-degraded baseline that masks injected chaos. Defaulting to
# IMAGE_TAG (0.1.0) would silently revert this on a redeploy. Override with
# SERVICE_TAG=<newer> only after rebuilding the Python service image.
SERVICE_TAG="${SERVICE_TAG:-0.1.7}"

log "ensuring namespace ${SERVICE_NAMESPACE}"
kubectl get ns "${SERVICE_NAMESPACE}" >/dev/null 2>&1 \
  || kubectl create namespace "${SERVICE_NAMESPACE}"

# Forward the postgres-exporter password set by 00-provision.sh into the
# chart so the postgres_exporter sidecar and the initdb monitoring role get
# the same value. Empty fallback is fine on first deploy: the chart default
# (`pg-exporter-demo-pass`) lets the cluster come up; we re-deploy after
# 00-provision.sh has run to rotate to the random password.
PG_EXPORTER_SET=()
if [[ -n "${PG_EXPORTER_PASSWORD:-}" ]]; then
  PG_EXPORTER_SET+=("--set" "infrastructure.postgres.monitoringUser.password=${PG_EXPORTER_PASSWORD}")
fi

# --reset-then-reuse-values keeps the frontend.* / chaosController.* overrides
# that scripts/05-deploy-frontend.sh and the chaos-controller bootstrap set
# via --set on previous releases, while ALSO refreshing the chart's default
# values from disk. The earlier --reuse-values approach silently dropped any
# new keys we added to helm/natwest-payments/values.yaml (helm treated the
# previous release's snapshot of chart defaults as canonical), which once
# caused services.ledger-service.language=java to be dropped on rollout and
# the Splunk OTel Java agent to crash with "Unrecognized value for
# otel.logs.exporter: otlp_proto_grpc" - the symptom was ledger-service
# emitting zero spans and floating on the Splunk Observability Service Map
# with no Postgres edge.
#
# scripts/05-deploy-frontend.sh enables the frontend (frontend.enabled=true,
# frontend.image.tag=<tag>, frontend.rum.*) by passing --set on top of
# values.yaml's defaults (where frontend.enabled is FALSE). Re-running this
# script must preserve those overrides; --reset-then-reuse-values does so
# while still letting chart updates (new keys, defaults, conditional
# branches) take effect.
#
# First-time installs (no existing release) handle this gracefully because
# helm only honours --reset-then-reuse-values when a prior release exists;
# the --install fallback path uses pure values.yaml + --set.
RELEASE_EXISTS=0
if helm -n "${SERVICE_NAMESPACE}" status natwest-payments >/dev/null 2>&1; then
  RELEASE_EXISTS=1
fi
REUSE_VALUES_FLAG=()
if [[ "${RELEASE_EXISTS}" == "1" ]]; then
  REUSE_VALUES_FLAG+=("--reset-then-reuse-values")
  log "existing release detected - using --reset-then-reuse-values to preserve frontend.*/chaosController.* overrides while picking up new chart defaults"
else
  log "no existing release - rendering from values.yaml (frontend disabled until 05-deploy-frontend.sh runs)"
fi

log "helm upgrade --install natwest-payments (image=${SERVICE_REPO}:${SERVICE_TAG}, ledger-java=${LEDGER_JAVA_REPO}:${LEDGER_JAVA_TAG})"
DEPLOY_START_EPOCH="$(date +%s)"
export DEPLOY_START_EPOCH
DEPLOY_OUTCOME=success

# Explicitly pin the APM Service Map topology design choices on every
# deploy. These values live in helm/natwest-payments/values.yaml but
# earlier releases stored conflicting --set overrides (e.g. heartbeat
# enabled=true from a January 2026 demo iteration), and --reset-then-
# reuse-values preserves those by design. The --set lines below force
# the current design (Approach A from the 2026-06-11 floating-services
# diagnosis):
#   * infra-heartbeat OFF: lets postgres, redis and kafka appear as
#     branded inferred glyphs (Postgres elephant / Redis cube / Kafka
#     swirl) instead of being merged into round first-class service
#     entities by the heartbeat's service.name=<broker> spans.
#   * payment-init kafkaPeerService=kafka (the chart default): the
#     producer span draws payment-init -> kafka, and the consumer span
#     on settlement-service continues the trace so APM draws kafka ->
#     settlement -> reconciliation -> reporting.
# To deviate, edit values.yaml AND remove the matching --set here in
# the same commit so future deploys don't silently restore the old
# behaviour.
APM_TOPOLOGY_SET=(
  --set "infrastructure.heartbeat.enabled=false"
  --set "services.payment-initiation-service.kafkaPeerService=kafka"
  --set "services.api-gateway.replicas=2"
  --set "services.api-gateway.downstreamTimeoutS=12"
  --set "services.routing-service.replicas=2"
  --set "services.ledger-service.language=java"
)

if ! helm upgrade --install natwest-payments "${HELM_CHART_DIR}" \
  --namespace "${SERVICE_NAMESPACE}" \
  "${REUSE_VALUES_FLAG[@]}" \
  --set image.repository="${SERVICE_REPO}" \
  --set image.tag="${SERVICE_TAG}" \
  --set "services.ledger-service.image.repository=${LEDGER_JAVA_REPO}" \
  --set "services.ledger-service.image.tag=${LEDGER_JAVA_TAG}" \
  "${PG_EXPORTER_SET[@]}" \
  "${APM_TOPOLOGY_SET[@]}" \
  --wait --timeout 7m; then
  DEPLOY_OUTCOME=failed
fi

# Post a deploy event (best-effort) into Splunk Observability + Splunk
# Enterprise so the DORA dashboard panels and the o11y deploy
# annotations show this run. Requires SPLUNK_REALM / SPLUNK_INGEST_TOKEN
# (o11y) and / or SPLUNK_HEC_URL / SPLUNK_HEC_TOKEN (Splunk Enterprise)
# in the environment; the script no-ops gracefully when neither is set
# so a developer running 03-deploy.sh locally is never blocked.
if [[ -x "${SCRIPT_DIR}/lib/post_deploy_event.sh" ]]; then
  "${SCRIPT_DIR}/lib/post_deploy_event.sh" \
    --service "natwest-payments" \
    --version "${IMAGE_TAG}" \
    --outcome "${DEPLOY_OUTCOME}" \
    --actor "${USER:-ci-bot}" \
    --commit "${GIT_SHA:-${IMAGE_TAG}}" \
    >/dev/null || true
fi

if [[ "${DEPLOY_OUTCOME}" == "failed" ]]; then
  echo "helm upgrade failed; deploy event posted as outcome=failed" >&2
  exit 1
fi

log "deployment status:"
kubectl -n "${SERVICE_NAMESPACE}" get deploy,svc -o wide
