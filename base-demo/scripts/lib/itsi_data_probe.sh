#!/usr/bin/env bash
# Probe the data sources that itsi/service-tree.yaml KPI base searches
# expect. Prints OK or WARN per source so the operator knows what to wire
# before/after running scripts/07-itsi-bootstrap.sh.
#
# Usage:
#   scripts/lib/itsi_data_probe.sh           # via SSH tunnel to demo EC2
#   scripts/lib/itsi_data_probe.sh --local   # if run on the Splunk box itself

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib.sh"
# lib.sh derives REPO_ROOT from BASH_SOURCE[1], which points at scripts/lib/
# when this file is the caller — override so paths resolve to the repo root.
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export REPO_ROOT TERRAFORM_DIR="${REPO_ROOT}/terraform"

require_cmd ssh curl jq

SPLUNK_ENTERPRISE_HOST="${SPLUNK_ENTERPRISE_HOST:-itsi.splunk-observability.com}"
SSH_USER="${SSH_USER:-ec2-user}"
SSH_KEY="${SSH_KEY:-${REPO_ROOT}/terraform/splunk-enterprise.pem}"
SSH_KEY="$(ensure_splunk_ssh_key "${SSH_KEY}")"
chmod 600 "${SSH_KEY}" 2>/dev/null || true
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:-admin}"
: "${TF_VAR_splunk_enterprise_admin_password:?Set TF_VAR_splunk_enterprise_admin_password (in .env or environment)}"

USE_LOCAL=0
[[ "${1:-}" == "--local" ]] && USE_LOCAL=1

# ---------------------------------------------------------------------------
# Connect: open SSH tunnel to splunkd management port if not local.
# ---------------------------------------------------------------------------
LOCAL_PORT=18089
TUNNEL_PID=""
cleanup() { [[ -n "${TUNNEL_PID}" ]] && kill "${TUNNEL_PID}" 2>/dev/null || true; }
trap cleanup EXIT

if (( ! USE_LOCAL )); then
  ssh -i "${SSH_KEY}" \
      -o StrictHostKeyChecking=accept-new \
      -o BatchMode=yes \
      -fN -L "${LOCAL_PORT}:127.0.0.1:8089" \
      "${SSH_USER}@${SPLUNK_ENTERPRISE_HOST}" </dev/null
  TUNNEL_PID="$(pgrep -f "ssh.*-L ${LOCAL_PORT}:127.0.0.1:8089.*${SSH_USER}@${SPLUNK_ENTERPRISE_HOST}" | head -1)"
  for _ in $(seq 1 20); do
    (echo > "/dev/tcp/127.0.0.1/${LOCAL_PORT}") >/dev/null 2>&1 && break
    sleep 0.5
  done
  TARGET="127.0.0.1:${LOCAL_PORT}"
else
  TARGET="127.0.0.1:8089"
fi

# ---------------------------------------------------------------------------
# Run a one-off SPL search via REST and return the event count.
# ---------------------------------------------------------------------------
splunk_search_count() {
  local spl="$1"
  # search/jobs/oneshot returns SID in the first call - we use the simplified
  # /search/v2/jobs/export endpoint instead, which streams results directly.
  curl -sk \
    -u "${SPLUNK_ADMIN_USER}:${TF_VAR_splunk_enterprise_admin_password}" \
    -d "search=search ${spl} | stats count" \
    -d "output_mode=json" \
    -d "earliest_time=-15m" \
    "https://${TARGET}/services/search/v2/jobs/export" \
  | tail -1 \
  | jq -r '.result.count // "0"' 2>/dev/null \
  || echo 0
}

# Same shape as splunk_search_count but uses | mstats so it works against
# metric-type indexes (e.g. itsi_im_metrics). The caller passes a constraint
# fragment like 'index=itsi_im_metrics metric_name IN (...)'; we wrap it with
# mstats count.
splunk_mstats_count() {
  local where="$1"
  curl -sk \
    -u "${SPLUNK_ADMIN_USER}:${TF_VAR_splunk_enterprise_admin_password}" \
    -d "search=| mstats count(_value) WHERE ${where} | stats sum(count(_value)) as count" \
    -d "output_mode=json" \
    -d "earliest_time=-15m" \
    "https://${TARGET}/services/search/v2/jobs/export" \
  | tail -1 \
  | jq -r '.result.count // "0"' 2>/dev/null \
  || echo 0
}

probe() {
  local label="$1"; shift
  local spl="$1"
  local count
  count="$(splunk_search_count "${spl}")"
  if [[ "${count}" =~ ^[0-9]+$ ]] && (( count > 0 )); then
    printf '\033[1;32m  [ok]   %-26s\033[0m count=%s spl=%s\n' "${label}" "${count}" "${spl}"
  else
    printf '\033[1;33m  [warn] %-26s\033[0m count=%s spl=%s\n' "${label}" "${count:-0}" "${spl}"
  fi
}

probe_metric() {
  local label="$1"; shift
  local where="$1"
  local count
  count="$(splunk_mstats_count "${where}")"
  if [[ "${count}" =~ ^[0-9]+$ ]] && (( count > 0 )); then
    printf '\033[1;32m  [ok]   %-26s\033[0m count=%s where=%s\n' "${label}" "${count}" "${where}"
  else
    printf '\033[1;33m  [warn] %-26s\033[0m count=%s where=%s\n' "${label}" "${count:-0}" "${where}"
  fi
}

log "ITSI data-source probe (last 15 min on ${SPLUNK_ENTERPRISE_HOST})"
probe "OTel logs"        'index=main sourcetype="otel:logs"'
probe "OTel traces"      'index=main sourcetype="otel:traces"'
probe_metric "OTel metrics" 'index=itsi_im_metrics metric_name=*'
probe "RUM events"       'index=splunkrum'
probe "Synthetics events" 'index=splunkrum event="synthetic_run"'

# Infra-receiver-specific probes. We accept either the OTel native metric
# names (redis.keys.evicted, postgresql.backends, kafka.brokers) or the
# prometheus/infra-equivalent names (redis_evicted_keys_total,
# pg_stat_database_numbackends, kafka_server_replicamanager_*) so a probe
# passes even when one of the two sources is unhealthy. This protects the
# nwpay_l4_redis / nwpay_l4_postgres / nwpay_l4_kafka KPI base searches.
log "Infra metrics (Redis / Postgres / Kafka via collector receivers)"
probe_metric "Redis evicted keys"   'index=itsi_im_metrics metric_name IN ("redis.keys.evicted","redis_evicted_keys_total")'
probe_metric "Postgres backends"    'index=itsi_im_metrics metric_name IN ("postgresql.backends","pg_stat_database_numbackends")'
probe_metric "Kafka brokers"        'index=itsi_im_metrics metric_name IN ("kafka.brokers","kafka_server_replicamanager_partitioncount")'

# Tier 1 infrastructure logs (nwpay_infra via collector filelog +
# transform/infra_routing; postgres:dbm via sqlquery/postgres).
log "Tier 1 infrastructure logs (nwpay_infra)"
probe "nginx access logs"   'index=nwpay_infra sourcetype="nginx:access"'
probe "Postgres container"  'index=nwpay_infra sourcetype="postgresql"'
probe "Redis container"     'index=nwpay_infra sourcetype="redis"'
probe "Kafka broker"        'index=nwpay_infra sourcetype="kafka"'
probe "Postgres DBM"        'index=nwpay_infra sourcetype="postgres:dbm"'

# Tier 2 banking/security audit (always-on - emitted by api-gateway and SPA).
log "Tier 2 banking/security audit"
probe "payment audit"       'index=nwpay_audit sourcetype="nwpay:payment_audit"'
probe "auth events"         'index=nwpay_audit sourcetype="nwpay:auth"'
probe "chaos events"        'index=nwpay_audit sourcetype="nwpay:chaos"'

# Tier 3 AWS cloud-plane logs (gated on var.aws_logs_to_hec_enabled). Probed
# best-effort; warn lines are expected when Tier 3 is off.
log "Tier 3 AWS cloud-plane logs (gated; warn = Tier 3 disabled or no events)"
probe "CloudTrail"          'index=aws_cloudtrail sourcetype="aws:cloudtrail"'
probe "VPC Flow Logs"       'index=aws_vpcflow sourcetype="aws:cloudwatchlogs:vpcflow"'
probe "GuardDuty findings"  'index=aws_guardduty sourcetype="aws:guardduty"'
probe "EKS audit"           'index=aws_eks_audit sourcetype="aws:cloudwatchlogs"'

cat <<EOF

If any source above is WARN:

  * "OTel traces"/"OTel metrics" missing
      -> helm upgrade the collector to pick up the splunkPlatform.tracesEnabled
         and splunkPlatform.metricsEnabled flags in collector/values.yaml.
         Then wait ~60 s and re-probe.

  * "RUM events" missing
      -> wire Log Observer Connect (LOC) in Splunk Observability Cloud:
         Logs -> Logs connections -> Add new connection -> Splunk Enterprise.
         Point at https://${SPLUNK_ENTERPRISE_HOST}:8000.

  * "Synthetics events" missing
      -> create the synthetic check manually in Splunk Observability
         (see scripts/lib/synthetic_check.sh) AND make sure the LOC link
         above is forwarding the Synthetics events index.

  * "Redis evicted keys" / "Postgres backends" / "Kafka brokers" missing
      -> the splunk-otel collector agent is not scraping the new infra
         exporter sidecars. Verify:
           1. helm/natwest-payments rollout includes redis_exporter,
              postgres_exporter, kafka jmx_exporter sidecars
              (kubectl get pod -n natwest -o wide and check container counts)
           2. allow-collector-scrape NetworkPolicy is in place
              (kubectl get netpol -n natwest)
           3. collector/values.yaml has receivers.redis / .postgresql /
              .kafkametrics / prometheus/infra wired into metrics/infra
              pipeline AND has been helm-upgraded onto the cluster.

  * "nginx access logs" / "Postgres container" / "Redis container" /
    "Kafka broker" / "Postgres DBM" missing
      -> infra pod logs route via the splunk-otel collector filelog receiver
         and transform/infra_routing in collector/values.yaml to
         index=nwpay_infra (postgresql / redis / kafka sourcetypes).
         Postgres DBM snapshots use the sqlquery/postgres receiver ->
         logs/dbm pipeline -> sourcetype=postgres:dbm.
         Verify:
           1. kubectl get pods -n natwest | grep -E 'postgres|redis|kafka'
           2. collector/values.yaml has logsCollection.containers.enabled=true
              and splunkPlatform.logsEnabled=true; re-run scripts/02-install-collector.sh
           3. scripts/00b-update-splunk-config.sh has created nwpay_infra
              and the otel-collector HEC token allow-list includes it.

  * Infra logs missing in Splunk Observability (APM Logs tab)
      -> Log Observer Connect must federate index=nwpay_infra (in addition
         to main and splunkrum). See README.md "Optional: Splunk Enterprise
         + Log Observer Connect". Infra logs need service.name stamped on
         the collector (transform/infra_routing) for APM node pivot.

  * "payment audit" / "auth events" missing
      -> Tier 2 audit emitter relies on auditEnabled=true in
         helm/natwest-payments/values.yaml and the audit-pepper Secret
         created by scripts/00-provision.sh. Confirm both are present
         and the api-gateway pod has an audit-tail sidecar.

  * Tier 3 AWS sources WARN
      -> Expected when var.aws_logs_to_hec_enabled=false (default). Flip
         the var, populate var.aws_firehose_egress_cidrs with the
         region's Firehose service IPs, and re-apply terraform.

ITSI KPIs whose data is missing will show "no data" but do not block the
service tree itself loading.
EOF
