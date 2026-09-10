#!/usr/bin/env bash
# scripts/00-preflight.sh
#
# Run ~5 minutes before showtime. Confirms every surface the demo touches is
# live before the audience walks in. Each check is a short, focused probe;
# every failure prints a one-line fix hint that maps onto an existing script
# or runbook step (run-of-show.md).
#
# Usage:
#   scripts/00-preflight.sh                # full run, ~25 seconds
#   scripts/00-preflight.sh --quick        # skip Splunk Observability + synthetic
#   scripts/00-preflight.sh --json         # machine-readable summary
#   scripts/00-preflight.sh --no-color
#
# Exit code:
#   0  - every check OK
#   1  - one or more checks FAIL
#   2  - missing dependency / invalid invocation
#
# The script never modifies cluster state; it only reads. Safe to run any
# time, including during the demo itself.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
QUICK=0
JSON=0
USE_COLOR=1

for arg in "$@"; do
  case "${arg}" in
    --quick)     QUICK=1 ;;
    --json)      JSON=1; USE_COLOR=0 ;;
    --no-color)  USE_COLOR=0 ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "00-preflight.sh: unknown flag '${arg}'" >&2
      exit 2
      ;;
  esac
done

# ANSI helpers. Stay quiet when --no-color / --json so the output stays
# friendly to CI capture.
if (( USE_COLOR )); then
  C_OK="$(printf '\033[1;32m')"     # bold green
  C_FAIL="$(printf '\033[1;31m')"   # bold red
  C_WARN="$(printf '\033[1;33m')"   # bold yellow
  C_INFO="$(printf '\033[1;34m')"   # bold blue
  C_DIM="$(printf '\033[2m')"
  C_RESET="$(printf '\033[0m')"
else
  C_OK=""; C_FAIL=""; C_WARN=""; C_INFO=""; C_DIM=""; C_RESET=""
fi

# ---------------------------------------------------------------------------
# Result aggregation. Every check appends a single line to RESULTS in the
# form  "<status>\t<name>\t<detail>\t<fix>"  where status is OK/WARN/FAIL.
# We render to text or JSON at the end so the per-check code can stay
# imperative and side-effect-free.
# ---------------------------------------------------------------------------
RESULTS=()
FAILS=0
WARNS=0

emit() {
  local status="$1"; local name="$2"; local detail="${3:-}"; local fix="${4:-}"
  case "${status}" in
    OK)   ;;
    WARN) WARNS=$((WARNS + 1)) ;;
    FAIL) FAILS=$((FAILS + 1)) ;;
    *) status="FAIL"; FAILS=$((FAILS + 1)) ;;
  esac
  # Tab-separated; never contains tabs in any field by construction below.
  RESULTS+=("${status}"$'\t'"${name}"$'\t'"${detail}"$'\t'"${fix}")

  if (( JSON )); then
    return 0
  fi

  local colour
  case "${status}" in
    OK)   colour="${C_OK}"   ;;
    WARN) colour="${C_WARN}" ;;
    FAIL) colour="${C_FAIL}" ;;
  esac
  printf '  %s[%-4s]%s %s' "${colour}" "${status}" "${C_RESET}" "${name}"
  if [[ -n "${detail}" ]]; then
    printf '  %s%s%s' "${C_DIM}" "${detail}" "${C_RESET}"
  fi
  printf '\n'
  if [[ "${status}" != "OK" && -n "${fix}" ]]; then
    printf '         %sfix:%s %s\n' "${C_DIM}" "${C_RESET}" "${fix}"
  fi
}

heading() {
  if (( JSON )); then return 0; fi
  printf '\n%s== %s ==%s\n' "${C_INFO}" "$1" "${C_RESET}"
}

# Helper: run a command with a short timeout and capture the exit code
# without aborting the script. Used by every external probe.
silent() {
  "$@" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 0. Tooling. If kubectl, terraform or curl are missing, no other check can
#    meaningfully run.
# ---------------------------------------------------------------------------
heading "Local tooling"

check_tool() {
  local cmd="$1"; local fix="$2"
  if command -v "${cmd}" >/dev/null 2>&1; then
    emit "OK" "${cmd} on PATH"
  else
    emit "FAIL" "${cmd} on PATH" "" "${fix}"
  fi
}
check_tool kubectl   "brew install kubectl  (or download from kubernetes.io)"
check_tool terraform "brew install terraform"
check_tool curl      "macOS preinstalled; otherwise apt/brew install curl"
check_tool jq        "brew install jq"
check_tool ssh       "macOS preinstalled"

# Bail early if the essentials aren't here. Everything else assumes them.
if (( FAILS > 0 )); then
  printf '\n%sCannot continue — install missing tooling and re-run.%s\n' "${C_FAIL}" "${C_RESET}"
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Terraform outputs. The demo wires almost every other check from
#    `terraform output -raw <foo>`; if state can't be read we punt and
#    leave the rest of the checks to operate in degraded mode.
# ---------------------------------------------------------------------------
heading "Terraform state"

TF_OK=0
if terraform -chdir="${TERRAFORM_DIR}" output -json >/dev/null 2>&1; then
  emit "OK" "terraform state readable" "$(terraform -chdir="${TERRAFORM_DIR}" workspace show 2>/dev/null || echo default)"
  TF_OK=1
else
  emit "FAIL" "terraform state readable" "" \
    "cd terraform && terraform init  (or run scripts/00-provision.sh first)"
fi

tf() {
  # tf_output but tolerant: returns empty string on any failure (incl. null).
  local v
  v="$(terraform -chdir="${TERRAFORM_DIR}" output -raw "$1" 2>/dev/null || true)"
  [[ "${v}" == "null" ]] && v=""
  printf '%s' "${v}"
}

CLUSTER_NAME=""; AWS_REGION=""; SPLUNK_REALM_TF=""
SPLUNK_PUBLIC_IP=""; HEC_PUBLIC=""; HEC_TOKEN_SCRIPTS=""; SPLUNK_FQDN=""
if (( TF_OK )); then
  CLUSTER_NAME="$(tf cluster_name)"
  AWS_REGION="$(tf region)"
  SPLUNK_PUBLIC_IP="$(tf splunk_enterprise_public_ip)"
  SPLUNK_FQDN="$(tf splunk_enterprise_fqdn)"
  HEC_PUBLIC="$(tf splunk_enterprise_hec_endpoint_public)"
  HEC_TOKEN_SCRIPTS="$(tf splunk_enterprise_hec_token_scripts)"
fi

# Splunk realm + token live in AWS Secrets Manager rather than a terraform
# output (sensitive). We probe the secret directly so we surface a clean
# error if the operator's AWS creds have lapsed.
SPLUNK_TOKEN=""; SPLUNK_REALM=""
if (( TF_OK )) && command -v aws >/dev/null 2>&1; then
  SECRET_ARN="$(tf splunk_token_secret_arn)"
  if [[ -n "${SECRET_ARN}" && -n "${AWS_REGION}" ]]; then
    if SECRET_JSON="$(aws secretsmanager get-secret-value \
        --region "${AWS_REGION}" --secret-id "${SECRET_ARN}" \
        --query SecretString --output text 2>/dev/null)"; then
      SPLUNK_REALM="$(printf '%s' "${SECRET_JSON}" | jq -r .realm 2>/dev/null || true)"
      SPLUNK_TOKEN="$(printf '%s' "${SECRET_JSON}" | jq -r .token 2>/dev/null || true)"
      [[ "${SPLUNK_REALM}" == "null" ]] && SPLUNK_REALM=""
      [[ "${SPLUNK_TOKEN}" == "null" ]] && SPLUNK_TOKEN=""
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 2. EKS / Kubernetes. The "all pods Ready" check is the single most common
#    failure mode of a demo opening cold; we surface a tight pod-by-pod
#    summary so the operator knows exactly which workload is unhappy.
# ---------------------------------------------------------------------------
heading "Kubernetes (EKS)"

KCTL_CTX="$(kubectl config current-context 2>/dev/null || true)"
if [[ -z "${KCTL_CTX}" ]]; then
  emit "FAIL" "kubectl context set" "" \
    "$(terraform -chdir="${TERRAFORM_DIR}" output -raw kubeconfig_command 2>/dev/null || echo "aws eks update-kubeconfig --name ${CLUSTER_NAME:-<cluster>} --region ${AWS_REGION:-<region>}")"
else
  emit "OK" "kubectl context set" "${KCTL_CTX}"
fi

# Probe API reachability with a hard 5s timeout so a stale context doesn't
# hang preflight forever.
if silent kubectl --request-timeout=5s get --raw=/readyz; then
  emit "OK" "Kubernetes API reachable"
else
  emit "FAIL" "Kubernetes API reachable" "" \
    "Refresh creds: aws eks update-kubeconfig --name ${CLUSTER_NAME:-<cluster>} --region ${AWS_REGION:-<region>}"
fi

# All Deployments in the natwest namespace must have availableReplicas
# matching .spec.replicas. We use a JSONPath compare; anything non-empty
# in `bad_deploys` means at least one deploy hasn't converged.
if silent kubectl get ns "${SERVICE_NAMESPACE}"; then
  bad_deploys="$(kubectl -n "${SERVICE_NAMESPACE}" get deploy \
    -o jsonpath='{range .items[?(@.status.availableReplicas<@.spec.replicas)]}{.metadata.name} (avail={.status.availableReplicas},spec={.spec.replicas}){"\n"}{end}' \
    2>/dev/null || true)"
  # The JSONPath filter above isn't bulletproof (missing fields evaluate
  # to 0); fall back to a parallel `kubectl get deploy --no-headers` parse.
  deploy_total="$(kubectl -n "${SERVICE_NAMESPACE}" get deploy --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
  deploy_unhealthy="$(kubectl -n "${SERVICE_NAMESPACE}" get deploy --no-headers 2>/dev/null \
    | awk '{
        split($2, r, "/");
        avail=r[1]; want=r[2];
        if (avail != want) print $1" ("$2")"
      }')"
  if [[ -n "${deploy_unhealthy}" ]]; then
    emit "FAIL" "all deployments Available (${SERVICE_NAMESPACE})" \
      "$(printf '%s' "${deploy_unhealthy}" | tr '\n' ',' | sed 's/,$//')" \
      "kubectl -n ${SERVICE_NAMESPACE} rollout status deploy/<name>  (or scripts/03-deploy.sh to redeploy)"
  else
    emit "OK" "all deployments Available (${SERVICE_NAMESPACE})" "${deploy_total} deployments"
  fi

  bad_pods="$(kubectl -n "${SERVICE_NAMESPACE}" get pods --no-headers 2>/dev/null \
    | awk '$3 != "Running" && $3 != "Completed" { print $1" ("$3")"}')"
  if [[ -n "${bad_pods}" ]]; then
    emit "FAIL" "all pods Running (${SERVICE_NAMESPACE})" \
      "$(printf '%s' "${bad_pods}" | tr '\n' ',' | sed 's/,$//')" \
      "kubectl -n ${SERVICE_NAMESPACE} describe pod <name>  ; check ECR pull / Secret"
  else
    emit "OK" "all pods Running (${SERVICE_NAMESPACE})"
  fi
else
  emit "FAIL" "namespace ${SERVICE_NAMESPACE} exists" "" \
    "scripts/03-deploy.sh    (helm install of the 24-service topology)"
fi

# Collector agent DaemonSet. The cluster-receiver and the agent must both be
# Running; if the agent is down nothing reaches Splunk Observability.
if silent kubectl get ns "${COLLECTOR_NAMESPACE}"; then
  bad_pods="$(kubectl -n "${COLLECTOR_NAMESPACE}" get pods --no-headers 2>/dev/null \
    | awk '$3 != "Running" && $3 != "Completed" { print $1" ("$3")"}')"
  if [[ -n "${bad_pods}" ]]; then
    emit "FAIL" "all pods Running (${COLLECTOR_NAMESPACE})" \
      "$(printf '%s' "${bad_pods}" | tr '\n' ',' | sed 's/,$//')" \
      "scripts/02-install-collector.sh    (reinstall the OTel Collector chart)"
  else
    emit "OK" "all pods Running (${COLLECTOR_NAMESPACE})"
  fi
else
  emit "WARN" "namespace ${COLLECTOR_NAMESPACE} exists" "" \
    "scripts/02-install-collector.sh    (install the OTel Collector)"
fi

# ---------------------------------------------------------------------------
# 3. Public SPA proxy. The demo's entry URL is
#    http://itsi.splunk-observability.com/  -- if the nginx box, the EIP, or
#    DNS is broken, the audience never gets past the splash screen.
# ---------------------------------------------------------------------------
heading "Public SPA proxy"

if [[ -z "${SPLUNK_PUBLIC_IP}" ]]; then
  emit "WARN" "Splunk Enterprise EC2 enabled" "" \
    "Set splunk_enterprise_enabled=true in terraform.tfvars and re-apply"
else
  emit "OK" "Splunk Enterprise EC2 public IP" "${SPLUNK_PUBLIC_IP}"

  # __proxy_health is served by nginx itself, so this test isolates a proxy
  # failure (nginx down) from an upstream failure (cluster down). 5 s
  # timeout because slow-then-recover would be worse than a clean FAIL.
  if curl -fsS -m 5 "http://${SPLUNK_PUBLIC_IP}/__proxy_health" 2>/dev/null | grep -q '^ok'; then
    emit "OK" "nginx /__proxy_health" "http://${SPLUNK_PUBLIC_IP}/__proxy_health"
  else
    emit "FAIL" "nginx /__proxy_health" "" \
      "scripts/05b-frontend-public-proxy.sh   (refresh upstream IPs + restart nginx)"
  fi

  # Upstream: the React bundle on port 80 hits a worker NodePort. If the
  # node-group rolled since the proxy last ran, this probe is the canary.
  if curl -fsS -m 8 -o /dev/null -w '%{http_code}' "http://${SPLUNK_PUBLIC_IP}/" 2>/dev/null | grep -q '^200$'; then
    emit "OK" "SPA root reachable" "http://${SPLUNK_PUBLIC_IP}/"
  else
    emit "FAIL" "SPA root reachable" "" \
      "Worker node-group may have rolled. Re-run scripts/05b-frontend-public-proxy.sh"
  fi

  # DNS. The talk-track quotes itsi.splunk-observability.com; if dig
  # returns anything other than the EIP, the audience will land on the
  # wrong stack.
  if [[ -n "${SPLUNK_FQDN}" ]]; then
    resolved="$(dig +short "${SPLUNK_FQDN}" A 2>/dev/null | tail -1 || true)"
    if [[ -z "${resolved}" ]]; then
      emit "WARN" "${SPLUNK_FQDN} resolves" "no A record returned" \
        "Re-apply terraform/splunk_enterprise_dns.tf, or wait for the Route53 TTL"
    elif [[ "${resolved}" == "${SPLUNK_PUBLIC_IP}" ]]; then
      emit "OK" "${SPLUNK_FQDN} -> EIP" "${resolved}"
    else
      emit "WARN" "${SPLUNK_FQDN} -> EIP" "DNS returns ${resolved}, EIP is ${SPLUNK_PUBLIC_IP}" \
        "Wait for TTL or run: terraform -chdir=terraform apply -target=aws_route53_record"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 4. Splunk Enterprise. HEC roundtrip + Splunk Web sanity. If HEC is
#    unreachable, every audit / chaos record from incident.sh silently
#    drops on the floor.
# ---------------------------------------------------------------------------
heading "Splunk Enterprise"

if [[ -z "${HEC_PUBLIC}" ]]; then
  emit "WARN" "splunk_enterprise_hec_endpoint_public output" "" \
    "splunk_enterprise_enabled=true required to publish HEC"
else
  # /services/collector/health is unauthenticated and returns 200 with a
  # body of {"text":"HEC is healthy","code":17}. It's the canonical Splunk
  # liveness probe.
  hec_health_url="${HEC_PUBLIC%/services/collector}/services/collector/health"
  if curl -fkS -m 6 "${hec_health_url}" 2>/dev/null | grep -q 'HEC is healthy'; then
    emit "OK" "HEC /health" "${hec_health_url}"
  else
    emit "FAIL" "HEC /health" "" \
      "Splunk Enterprise EC2 may be stopped. Check: aws ec2 describe-instances --instance-ids ${SPLUNK_PUBLIC_IP:+<id>}"
  fi

  # Authenticated POST roundtrip into nwpay_audit. We send a single
  # preflight-marker event so the operator can prove end-to-end that the
  # demo's audit pipeline is open. The event is tiny (~150 bytes) and
  # idempotent, so re-running preflight 50 times doesn't pollute anything.
  if [[ -n "${HEC_TOKEN_SCRIPTS}" ]]; then
    payload="$(cat <<JSON
{"time": $(date +%s), "host":"preflight",
 "source":"00-preflight.sh", "sourcetype":"nwpay:preflight",
 "index":"nwpay_audit",
 "event":{
   "@timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)",
   "event_type":"preflight",
   "actor":"${USER:-unknown}",
   "git_sha":"$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)",
   "deployment_environment":"demo"
 }}
JSON
)"
    if curl -fksS -m 6 \
         -H "Authorization: Splunk ${HEC_TOKEN_SCRIPTS}" \
         -H "Content-Type: application/json" \
         --data "${payload}" \
         "${HEC_PUBLIC%/}/event" >/dev/null 2>&1; then
      emit "OK" "HEC POST to nwpay_audit"
    else
      emit "FAIL" "HEC POST to nwpay_audit" "" \
        "Token mismatch or index ACL. Re-apply terraform/splunk_enterprise.tf"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 4b. ThousandEyes ingest freshness. The TE Streaming integration carries an
#     `enabled` flag on each stream that flips to false the moment TE sees
#     enough consecutive HTTP errors from the HEC endpoint (e.g. the Splunk
#     EC2 was rebuilt and the HEC token is now stale). Once disabled, TE
#     never auto-recovers - the operator has to PUT enabled=true via the
#     TE v7 API (or click "Enable" per stream in the TE UI). When the
#     streams are dark, all 21 ThousandEyes-fed ITSI KPIs silently sit at
#     zero - the demo's synthetic outcomes panels all read "no impact"
#     even during a real outage. We caught this in production after the
#     streams had been off for 40 days, so the check below treats anything
#     older than 30 minutes as FAIL.
#
#     Probe: the public HEC token lets us POST/GET nothing useful for a
#     freshness query, so we go through the admin REST API on port 8089
#     (the same one HEC's /services/collector/health sits on). Splunk
#     Enterprise rejects unauthenticated reads of indexed data, so we
#     wrap in a search against the admin user that the install script
#     wrote into Secrets Manager. The check is gated on the Splunk
#     Enterprise EC2 being present + the admin password being reachable
#     (mirrors the gating used for the HEC POST check above).
# ---------------------------------------------------------------------------
heading "ThousandEyes ingest freshness"

# The Splunk admin password is stored in the operator's .env (under
# TF_VAR_splunk_enterprise_admin_password) and consumed by Terraform on
# `apply` - there's no AWS Secrets Manager copy because Splunk's user-
# seed file accepts the password only once at cloud-init time. We read
# the .env file directly; if it's not present (CI environment, fresh
# clone), the check emits WARN rather than FAIL because the rest of
# preflight may still be useful.
TE_ADMIN_PW=""
if [[ -f "${REPO_ROOT}/.env" ]]; then
  TE_ADMIN_PW="$(grep -E '^TF_VAR_splunk_enterprise_admin_password=' "${REPO_ROOT}/.env" \
    | head -1 | cut -d= -f2- | sed 's/^"\(.*\)"$/\1/' || true)"
fi

if [[ -z "${SPLUNK_PUBLIC_IP}" ]]; then
  emit "WARN" "ThousandEyes ingest fresh" "Splunk Enterprise EC2 not provisioned" \
    "splunk_enterprise_enabled=true in terraform.tfvars + re-apply"
elif [[ -z "${TE_ADMIN_PW}" ]]; then
  emit "WARN" "ThousandEyes ingest fresh" "couldn't resolve Splunk admin password" \
    "ensure aws sm get-secret-value works, or set TF_VAR_splunk_enterprise_admin_password in .env"
else
  # `| tstats count where index=thousandeyes earliest=-30m` is a metric-
  # store-friendly equivalent that returns in <300ms even when the
  # index has a year of history. Capture stdout + stderr, parse the
  # last numeric column we see (Splunk emits a CSV header).
  te_resp="$(curl -ksS -m 8 \
    -u "admin:${TE_ADMIN_PW}" \
    -d 'search=| tstats count WHERE index=thousandeyes earliest=-30m' \
    -d 'output_mode=csv' \
    -d 'exec_mode=oneshot' \
    "https://${SPLUNK_PUBLIC_IP}:8089/services/search/jobs/export" 2>/dev/null \
    | tail -1 || echo "")"
  te_count="$(printf '%s' "${te_resp}" | tr -d '"' | head -1)"
  case "${te_count}" in
    ''|*[!0-9]*)
      emit "WARN" "ThousandEyes ingest fresh" "Splunk REST call returned non-numeric (${te_resp:-empty})" \
        "Try: ssh to splunk box and run | tstats count where index=thousandeyes earliest=-30m manually"
      ;;
    0)
      emit "FAIL" "ThousandEyes ingest fresh" "0 events in last 30 min (streams may be disabled)" \
        "scripts/09-configure-splunk-te-inputs.sh   (idempotently re-enables TE streams)"
      ;;
    *)
      emit "OK" "ThousandEyes ingest fresh" "${te_count} events in last 30 min"
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# 5. Splunk Observability. Realm + token must be valid; otherwise no RUM, no
#    APM, no Tag Spotlight. We skip in --quick because this probes a public
#    endpoint and slows preflight by ~2s.
# ---------------------------------------------------------------------------
if (( ! QUICK )); then
  heading "Splunk Observability Cloud"

  if [[ -z "${SPLUNK_TOKEN}" || -z "${SPLUNK_REALM}" ]]; then
    emit "WARN" "ingest token + realm in Secrets Manager" "" \
      "aws secretsmanager get-secret-value (or scripts/00-provision.sh to bootstrap)"
  else
    # POST a zero-payload event to /v2/event. 200 means token + realm OK;
    # 401 means the token's gone; anything else means the realm is wrong
    # (DNS failure or signalfx_token mismatch).
    o11y_url="https://ingest.${SPLUNK_REALM}.signalfx.com/v2/event"
    http_code="$(curl -sS -m 6 -o /dev/null -w '%{http_code}' \
      -X POST -H "Content-Type: application/json" -H "X-SF-TOKEN: ${SPLUNK_TOKEN}" \
      --data '[{"category":"USER_DEFINED","eventType":"natwest.preflight","dimensions":{"environment":"demo"}}]' \
      "${o11y_url}" 2>/dev/null || echo 000)"
    case "${http_code}" in
      200|202)
        emit "OK" "ingest token valid" "realm=${SPLUNK_REALM}"
        ;;
      401|403)
        emit "FAIL" "ingest token valid" "HTTP ${http_code}" \
          "Rotate the Splunk Observability ingest token + update Secrets Manager"
        ;;
      *)
        emit "WARN" "ingest token valid" "HTTP ${http_code}" \
          "Check the realm value (us0/us1/eu0/eu1) and outbound network"
        ;;
    esac
  fi

  heading "APM service-map topology"
  apm_host="${SPLUNK_FQDN:-}"
  if [[ -z "${apm_host}" ]]; then
    apm_host="${SPLUNK_PUBLIC_IP:-}"
  fi
  apm_pw="${TE_ADMIN_PW:-}"
  if [[ -z "${apm_pw}" && -f "${REPO_ROOT}/.env" ]]; then
    apm_pw="$(grep -E '^TF_VAR_splunk_enterprise_admin_password=' "${REPO_ROOT}/.env" \
      | head -1 | cut -d= -f2- | sed 's/^"\(.*\)"$/\1/' || true)"
  fi
  if [[ -z "${apm_host}" || -z "${apm_pw}" ]]; then
    emit "WARN" "APM map edges (no floating nodes)" "Splunk host/password unavailable" \
      "python3 scripts/lib/verify_apm_topology.py --host <splunk>"
  elif python3 "${SCRIPT_DIR}/lib/verify_apm_topology.py" \
      --host "${apm_host}" --password "${apm_pw}" >/tmp/nwpay-apm-topology.out 2>&1; then
    emit "OK" "APM map edges (no floating nodes)" "$(tail -1 /tmp/nwpay-apm-topology.out)"
  else
    emit "FAIL" "APM map edges (no floating nodes)" "$(grep '^FAIL' /tmp/nwpay-apm-topology.out | head -3 | tr '\n' '; ')" \
      "make repair-apm-topology   (or scripts/08-repair-apm-topology.sh)"
  fi
fi

# ---------------------------------------------------------------------------
# 6. Incident baseline. If the operator forgot to run `scripts/incident.sh
#    recover` after the previous demo, fraud-detection-service is still
#    running the regressed kernel and the customer-tier throttle is still
#    on Bronze. Show what we found; flag anything non-default as WARN
#    (not FAIL) — operators sometimes intentionally pre-arm an incident.
# ---------------------------------------------------------------------------
heading "Incident baseline (kubectl set env --list)"

if silent kubectl get ns "${SERVICE_NAMESPACE}"; then
  # Allow-list of values that match either the helm chart's nominal defaults
  # (see helm/natwest-payments/values.yaml: defaults.errorRate=0.01,
  # tierBehaviour.throttleProb="bronze:0.03,silver:0.0,gold:0.0",
  # sanctions.cacheHitRate=0.97, fraud.cacheHitRate=0.85, fraud.errorRate=0.02,
  # swift.errorRate=0.05, services with no cache override report
  # CACHE_HIT_RATE=0) or the post-`incident.sh recover` zero state. Anything
  # else is either an active chaos toggle or a manual override and is worth
  # surfacing so the operator can decide before going on stage.
  hot_vars="$(
    for d in fraud-detection-service swift-network sanctions-aml-service ledger-service api-gateway; do
      kubectl -n "${SERVICE_NAMESPACE}" set env "deploy/${d}" --list 2>/dev/null \
        | awk -v deploy="${d}" '
          /^ERROR_RATE=0\.0[0-9]+$/                                  { next }
          /^ERROR_RATE=0\.05$/                                       { next }
          /^CACHE_HIT_RATE=0$/                                       { next }
          /^CACHE_HIT_RATE=0\.85$/                                   { next }
          /^CACHE_HIT_RATE=0\.9[0-9]$/                               { next }
          /^DB_LATENCY_MS=0$/                                        { next }
          /^CPU_REGRESSION_ENABLED=false$/                           { next }
          /^TIER_THROTTLE_PROB=bronze:0\.0,silver:0\.0,gold:0\.0$/   { next }
          /^TIER_THROTTLE_PROB=bronze:0\.03,silver:0\.0,gold:0\.0$/  { next }
          /^(ERROR_RATE|CACHE_HIT_RATE|DB_LATENCY_MS|CPU_REGRESSION_ENABLED|TIER_THROTTLE_PROB)=/ {
            print deploy"::" $0
          }'
    done | tr '\n' ',' | sed 's/,$//'
  )"
  if [[ -z "${hot_vars}" ]]; then
    emit "OK" "all deployments at baseline" "fraud / swift / sanctions / ledger / gateway"
  else
    emit "WARN" "deployment vars NOT at baseline" "${hot_vars}" \
      "scripts/incident.sh recover    (resets every chaos toggle to default)"
  fi
fi

# ---------------------------------------------------------------------------
# Render and exit.
# ---------------------------------------------------------------------------
total="${#RESULTS[@]}"

if (( JSON )); then
  printf '{\n  "checks": [\n'
  for i in "${!RESULTS[@]}"; do
    IFS=$'\t' read -r status name detail fix <<<"${RESULTS[$i]}"
    sep=","
    [[ $((i + 1)) -eq ${total} ]] && sep=""
    # Naive JSON escape: backslash + double-quote only. Fields never
    # contain newlines (constructed line-by-line above).
    name_e="${name//\\/\\\\}";   name_e="${name_e//\"/\\\"}"
    detail_e="${detail//\\/\\\\}"; detail_e="${detail_e//\"/\\\"}"
    fix_e="${fix//\\/\\\\}";     fix_e="${fix_e//\"/\\\"}"
    printf '    {"status":"%s","name":"%s","detail":"%s","fix":"%s"}%s\n' \
      "${status}" "${name_e}" "${detail_e}" "${fix_e}" "${sep}"
  done
  printf '  ],\n  "summary": {"total": %d, "fails": %d, "warns": %d}\n}\n' \
    "${total}" "${FAILS}" "${WARNS}"
else
  printf '\n'
  if (( FAILS == 0 && WARNS == 0 )); then
    printf '%sAll %d checks passed.%s\n' "${C_OK}" "${total}" "${C_RESET}"
  elif (( FAILS == 0 )); then
    printf '%s%d/%d checks passed (%d warnings).%s\n' \
      "${C_WARN}" "$((total - WARNS))" "${total}" "${WARNS}" "${C_RESET}"
  else
    printf '%s%d/%d checks passed (%d FAIL, %d WARN).%s\n' \
      "${C_FAIL}" "$((total - FAILS - WARNS))" "${total}" "${FAILS}" "${WARNS}" "${C_RESET}"
  fi
fi

(( FAILS == 0 )) || exit 1
exit 0
