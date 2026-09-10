#!/usr/bin/env bash
# Install the Splunk OpenTelemetry Collector Helm chart into the cluster.
# Pulls the Splunk Observability ingest token from AWS Secrets Manager (created
# by Terraform) and stores it as a Kubernetes Secret referenced by the chart.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_cmd kubectl helm aws jq terraform

REGION=$(tf_output region)
CLUSTER_NAME=$(tf_output cluster_name)
SECRET_ARN=$(tf_output splunk_token_secret_arn)

log "fetching Splunk access token from Secrets Manager (${SECRET_ARN})"
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --region "${REGION}" \
  --secret-id "${SECRET_ARN}" \
  --query SecretString --output text)

SPLUNK_REALM=$(echo "${SECRET_JSON}" | jq -r .realm)
SPLUNK_TOKEN=$(echo "${SECRET_JSON}" | jq -r .token)

if [[ -z "${SPLUNK_REALM}" || -z "${SPLUNK_TOKEN}" || "${SPLUNK_REALM}" == "null" ]]; then
  fail "could not read Splunk realm/token from Secrets Manager"
fi

log "ensuring namespace ${COLLECTOR_NAMESPACE}"
kubectl get ns "${COLLECTOR_NAMESPACE}" >/dev/null 2>&1 \
  || kubectl create namespace "${COLLECTOR_NAMESPACE}"

# Optional: pre-stage the Splunk Platform HEC token alongside the o11y token in
# the same Secret. The chart looks up `splunk_platform_hec_token` here when
# splunkPlatform.token is set, so seeding it now means the collector pods come
# up clean instead of erroring out with "couldn't find key" the first time.
SPLUNK_HEC_TOKEN_FOR_SECRET=$(tf_output splunk_enterprise_hec_token 2>/dev/null || true)

log "creating/updating Kubernetes Secret 'splunk-access-token'"
SECRET_ARGS=(
  --from-literal=splunk_observability_access_token="${SPLUNK_TOKEN}"
)
if [[ -n "${SPLUNK_HEC_TOKEN_FOR_SECRET}" && "${SPLUNK_HEC_TOKEN_FOR_SECRET}" != "null" ]]; then
  SECRET_ARGS+=(--from-literal=splunk_platform_hec_token="${SPLUNK_HEC_TOKEN_FOR_SECRET}")
fi
kubectl -n "${COLLECTOR_NAMESPACE}" create secret generic splunk-access-token \
  "${SECRET_ARGS[@]}" \
  --dry-run=client -o yaml | kubectl apply -f -

log "adding Splunk OTel Collector helm repo"
helm repo add splunk-otel-collector-chart https://signalfx.github.io/splunk-otel-collector-chart >/dev/null 2>&1 || true
helm repo update >/dev/null

# Optional: wire the collector to the in-VPC Splunk Enterprise instance for
# Log Observer Connect. Reads the HEC endpoint + token from terraform outputs
# (only present when var.splunk_enterprise_enabled = true). When the outputs
# are empty/null, the collector still ships traces/metrics to Splunk
# Observability but skips the splunk-platform log sink. The token is also
# already in the Secret we just created (splunk_platform_hec_token), so the
# chart can resolve ${SPLUNK_PLATFORM_HEC_TOKEN} at runtime.
SPLUNK_HEC_ENDPOINT=$(tf_output splunk_enterprise_hec_endpoint 2>/dev/null || true)

# Splunk HEC has separate path handlers per data type:
#   /services/collector        -> generic, accepts both events and metrics
#   /services/collector/event  -> events only (rejects metric-format with 400)
#   /services/collector/raw    -> raw text events
# The OTel splunk_hec exporter does not rewrite the path per data_type, so a
# `/event` suffix breaks the metrics pipeline. Strip it so the same URL works
# for logs, traces, AND metrics.
SPLUNK_HEC_ENDPOINT="${SPLUNK_HEC_ENDPOINT%/event}"

EXTRA_HELM_ARGS=()
if [[ -n "${SPLUNK_HEC_ENDPOINT}" && "${SPLUNK_HEC_ENDPOINT}" != "null" \
      && -n "${SPLUNK_HEC_TOKEN_FOR_SECRET}" && "${SPLUNK_HEC_TOKEN_FOR_SECRET}" != "null" ]]; then
  log "wiring splunkPlatform sink to ${SPLUNK_HEC_ENDPOINT}"
  EXTRA_HELM_ARGS+=(
    --set "splunkPlatform.endpoint=${SPLUNK_HEC_ENDPOINT}"
    --set "splunkPlatform.token=${SPLUNK_HEC_TOKEN_FOR_SECRET}"
    --set "splunkPlatform.insecureSkipVerify=true"
  )
else
  # Loud warning rather than silent skip - missing outputs almost always mean
  # the Splunk Enterprise HEC fan-out is broken end-to-end (no otel:metrics in
  # index=main, ITSI KPIs show "no data"). The values.yaml `metrics/infra`
  # pipeline references `splunk_hec/platform_metrics` which the chart only
  # auto-creates when the splunkPlatform.* values above are set; without them
  # `helm upgrade` will fail validation. Re-run `terraform apply` to register
  # the missing outputs in state, then re-run this script.
  log "WARN: splunkPlatform fan-out skipped - both splunk_enterprise_hec_endpoint"
  log "      and splunk_enterprise_hec_token must be present as terraform outputs."
  log "      Run 'terraform -chdir=terraform apply' to register them, then rerun"
  log "      scripts/02-install-collector.sh."
  log "      endpoint='${SPLUNK_HEC_ENDPOINT:-<unset>}'  token=$([[ -n \"${SPLUNK_HEC_TOKEN_FOR_SECRET:-}\" ]] && echo '<set>' || echo '<unset>')"
fi

log "installing/upgrading splunk-otel-collector in namespace ${COLLECTOR_NAMESPACE}"
# Use the ${arr[@]+"${arr[@]}"} idiom so an empty EXTRA_HELM_ARGS array
# does not trip set -u with bash 4.x.
helm upgrade --install splunk-otel-collector splunk-otel-collector-chart/splunk-otel-collector \
  --namespace "${COLLECTOR_NAMESPACE}" \
  --values "${COLLECTOR_VALUES}" \
  --set splunkObservability.realm="${SPLUNK_REALM}" \
  --set clusterName="${CLUSTER_NAME}" \
  ${EXTRA_HELM_ARGS[@]+"${EXTRA_HELM_ARGS[@]}"} \
  --wait --timeout 5m

log "collector pods:"
kubectl -n "${COLLECTOR_NAMESPACE}" get pods

unset SPLUNK_TOKEN SECRET_JSON SPLUNK_HEC_TOKEN_FOR_SECRET
log "done. Traces/metrics/logs will land in Splunk Observability realm '${SPLUNK_REALM}'."
