#!/usr/bin/env bash
# Idempotent Splunk APM service-map topology repair (kubectl path).
#
# Mirrors chaos-controller/app/scenarios.py::_repair_apm_topology so
# scripts/incident.sh recover and make repair-apm-topology can restore
# peer.service wiring without the chaos-controller HTTP API.
#
# Usage (after sourcing scripts/lib.sh):
#   source scripts/lib/apm_topology_repair.sh
#   apm_topology_repair

# shellcheck disable=SC2034
APM_PEER_SERVICE_MAPPING="${APM_PEER_SERVICE_MAPPING:-postgres.natwest.svc.cluster.local=postgres,kafka.natwest.svc.cluster.local=kafka,redis.natwest.svc.cluster.local=redis}"

apm_topology_repair() {
  local ns="${NS:-${SERVICE_NAMESPACE:-natwest}}"
  require_cmd kubectl

  log "APM topology repair: re-applying peer.service wiring and steady-state replicas"

  _apm_deploy_exists() {
    kubectl -n "${ns}" get deploy "$1" >/dev/null 2>&1
  }

  _apm_set_env() {
    local deploy="$1"
    shift
    if ! _apm_deploy_exists "${deploy}"; then
      warn "skip set env deploy/${deploy} (not found)"
      return 0
    fi
    log "set env on deploy/${deploy}: $*"
    kubectl -n "${ns}" set env "deploy/${deploy}" "$@" >/dev/null
    kubectl -n "${ns}" rollout status "deploy/${deploy}" --timeout=120s
  }

  _apm_scale_if_drift() {
    local deploy="$1" want="$2"
    if ! _apm_deploy_exists "${deploy}"; then
      return 0
    fi
    local have
    have="$(kubectl -n "${ns}" get deploy "${deploy}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")"
    if [[ -n "${have}" && "${have}" != "${want}" ]]; then
      log "scale deploy/${deploy}: ${have} -> ${want}"
      kubectl -n "${ns}" scale "deploy/${deploy}" --replicas="${want}" >/dev/null
      kubectl -n "${ns}" rollout status "deploy/${deploy}" --timeout=180s
    fi
  }

  _apm_restore_infra_replica() {
    local deploy="$1"
    if ! _apm_deploy_exists "${deploy}"; then
      return 0
    fi
    local have
    have="$(kubectl -n "${ns}" get deploy "${deploy}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)"
    if [[ "${have}" -lt 1 ]]; then
      log "restore infra deploy/${deploy} from ${have} -> 1"
      kubectl -n "${ns}" scale "deploy/${deploy}" --replicas=1 >/dev/null
      kubectl -n "${ns}" rollout status "deploy/${deploy}" --timeout=180s
    fi
  }

  if _apm_deploy_exists payment-initiation-service; then
    _apm_set_env payment-initiation-service \
      "KAFKA_PEER_SERVICE=kafka" \
      "KAFKA_PRODUCER_ENABLED=true" \
      "OTEL_INSTRUMENTATION_COMMON_PEER_SERVICE_MAPPING=${APM_PEER_SERVICE_MAPPING}"
  fi

  for deploy in sanctions-aml-service fraud-detection-service settlement-service; do
    _apm_set_env "${deploy}" \
      "OTEL_INSTRUMENTATION_COMMON_PEER_SERVICE_MAPPING=${APM_PEER_SERVICE_MAPPING}"
  done

  if _apm_deploy_exists settlement-service; then
    _apm_set_env settlement-service "KAFKA_CONSUMER_ENABLED=true"
  fi

  if _apm_deploy_exists ledger-service; then
    _apm_set_env ledger-service \
      "DB_LATENCY_MS=0" \
      "OTEL_LOGS_EXPORTER=otlp" \
      "OTEL_INSTRUMENTATION_COMMON_PEER_SERVICE_MAPPING=${APM_PEER_SERVICE_MAPPING}"
  fi

  if _apm_deploy_exists api-gateway; then
    _apm_set_env api-gateway \
      "DOWNSTREAM_TIMEOUT_S=12.0" \
      "OTEL_INSTRUMENTATION_COMMON_PEER_SERVICE_MAPPING=${APM_PEER_SERVICE_MAPPING}"
  fi

  _apm_scale_if_drift api-gateway 2
  _apm_scale_if_drift routing-service 2
  _apm_scale_if_drift payment-initiation-service 3
  _apm_scale_if_drift payment-validation-service 2

  for infra in postgres redis kafka; do
    _apm_restore_infra_replica "${infra}"
  done

  if kubectl -n "${ns}" get cronjob infra-heartbeat >/dev/null 2>&1; then
    log "suspend CronJob/infra-heartbeat (keeps branded inferred postgres/redis/kafka glyphs)"
    kubectl -n "${ns}" patch cronjob infra-heartbeat \
      --type merge -p '{"spec":{"suspend":true}}' >/dev/null 2>&1 || true
  fi

  if _apm_deploy_exists traffic-generator; then
    local tg_pod
    tg_pod="$(kubectl -n "${ns}" get pods -l app.kubernetes.io/name=traffic-generator \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "${tg_pod}" ]]; then
      log "restart traffic-generator pod/${tg_pod} (refresh peer.service CLIENT spans)"
      kubectl -n "${ns}" delete pod "${tg_pod}" --grace-period=0 --wait=false >/dev/null 2>&1 || true
    fi
  fi

  log "APM topology repair complete (allow ~90s for new trace windows)"
}
