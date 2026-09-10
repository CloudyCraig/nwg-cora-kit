#!/usr/bin/env bash
# Smoke test for the expanded log pipeline.
#
# For each new HEC token:
#   1. POST a synthetic event into a known index/sourcetype.
#   2. Wait briefly for indexing to settle.
#   3. Issue a Splunk REST search against that index and confirm the
#      synthetic event landed.
#
# Per-source pass/fail line printed as it goes; final summary shows total
# OK / WARN / FAIL counts. Exits non-zero if any HEC token outright
# rejects (auth/SSL/network) or any expected source returns 0 events
# beyond a generous grace window. WARN (e.g. AWS sources when Tier 3 is
# disabled) does not fail the run.
#
# Usage:
#   scripts/11-verify-logs.sh                # uses terraform outputs
#   scripts/11-verify-logs.sh --quick        # skip the search-back step

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_cmd curl jq terraform

SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:-admin}"
: "${TF_VAR_splunk_enterprise_admin_password:?Set TF_VAR_splunk_enterprise_admin_password (in .env or environment)}"

QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

# ---------------------------------------------------------------------------
# Discover HEC endpoint + tokens from terraform outputs.
# ---------------------------------------------------------------------------
log "Pulling HEC endpoint and tokens from terraform outputs"
HEC_PUBLIC="$(tf_output splunk_enterprise_hec_endpoint_public 2>/dev/null || true)"
HEC_PRIVATE="$(tf_output splunk_enterprise_hec_endpoint 2>/dev/null || true)"
TOKEN_OTEL="$(tf_output splunk_enterprise_hec_token 2>/dev/null || true)"
TOKEN_FIREHOSE="$(tf_output splunk_enterprise_hec_token_firehose 2>/dev/null || true)"
TOKEN_SCRIPTS="$(tf_output splunk_enterprise_hec_token_scripts 2>/dev/null || true)"

if [[ -z "${HEC_PUBLIC}" ]]; then
  fail "splunk_enterprise_hec_endpoint_public is empty - is Splunk Enterprise enabled and applied?"
fi
HEC_TARGET="${HEC_PUBLIC}"

# Splunk Enterprise REST endpoint for search. Reuse the public FQDN at 8089.
# The FQDN uses a self-signed cert, so we pass -k.
SPLUNK_HOST="$(echo "${HEC_TARGET}" | sed -E 's#https?://([^:/]+).*#\1#')"
SPLUNK_REST="https://${SPLUNK_HOST}:8089"

OK=0; WARN=0; FAIL=0

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

# post_event <token> <index> <sourcetype> <event_id>
# Returns HTTP 200 / 400 / 401 / etc.
post_event() {
  local token="$1" index="$2" sourcetype="$3" event_id="$4"
  local payload
  payload=$(jq -nc \
    --arg index "${index}" \
    --arg sourcetype "${sourcetype}" \
    --arg event_id "${event_id}" \
    --arg ts "$(date -u +%s)" \
    '{event:{event_id:$event_id,marker:"verify-logs.sh",ts:$ts},sourcetype:$sourcetype,index:$index}')

  curl -ksS \
    -o /dev/null \
    -w '%{http_code}' \
    -H "Authorization: Splunk ${token}" \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    "${HEC_TARGET}"
}

# search_back_spl <spl>
# Returns the integer count from an arbitrary SPL fragment.
search_back_spl() {
  local spl="$1"
  curl -ksS \
    -u "${SPLUNK_ADMIN_USER}:${TF_VAR_splunk_enterprise_admin_password}" \
    -d "search=search ${spl} | stats count" \
    -d "output_mode=json" \
    -d "earliest_time=-15m" \
    "${SPLUNK_REST}/services/search/v2/jobs/export" \
    | tail -1 \
    | jq -r '.result.count // "0"' 2>/dev/null \
    || echo 0
}

# probe_infra_logs <label> <spl>
probe_infra_logs() {
  local label="$1" spl="$2"
  local count
  count="$(search_back_spl "${spl}")"
  if [[ "${count}" =~ ^[0-9]+$ ]] && (( count > 0 )); then
    printf '\033[1;32m  [ok]   %-32s\033[0m count=%s\n' "${label}" "${count}"
    OK=$((OK + 1))
  else
    printf '\033[1;33m  [warn] %-32s\033[0m count=%s (no events in last 15m)\n' "${label}" "${count:-0}"
    WARN=$((WARN + 1))
  fi
}

# search_back <index> <event_id>
# Returns the integer count of matching events.
search_back() {
  local index="$1" event_id="$2"
  curl -ksS \
    -u "${SPLUNK_ADMIN_USER}:${TF_VAR_splunk_enterprise_admin_password}" \
    -d "search=search index=${index} marker=\"verify-logs.sh\" event_id=\"${event_id}\" | stats count" \
    -d "output_mode=json" \
    -d "earliest_time=-5m" \
    "${SPLUNK_REST}/services/search/v2/jobs/export" \
    | tail -1 \
    | jq -r '.result.count // "0"' 2>/dev/null \
    || echo 0
}

# verify <label> <token> <index> <sourcetype>
verify() {
  local label="$1" token="$2" index="$3" sourcetype="$4"

  if [[ -z "${token}" || "${token}" == "null" ]]; then
    printf '\033[1;33m  [warn] %-32s\033[0m token missing (terraform not applied with this feature)\n' "${label}"
    WARN=$((WARN + 1))
    return
  fi

  local event_id
  event_id="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N)"

  local code
  code="$(post_event "${token}" "${index}" "${sourcetype}" "${event_id}")"
  if [[ "${code}" != "200" ]]; then
    printf '\033[1;31m  [fail] %-32s\033[0m HEC POST returned HTTP %s\n' "${label}" "${code}"
    FAIL=$((FAIL + 1))
    return
  fi

  if (( QUICK )); then
    printf '\033[1;32m  [ok]   %-32s\033[0m HTTP 200 (search-back skipped)\n' "${label}"
    OK=$((OK + 1))
    return
  fi

  local n=0 count=0
  for n in 1 2 3 4 5 6; do
    sleep 5
    count="$(search_back "${index}" "${event_id}")"
    [[ "${count}" =~ ^[0-9]+$ ]] || count=0
    if (( count > 0 )); then
      printf '\033[1;32m  [ok]   %-32s\033[0m HEC POST OK, search returned %s\n' "${label}" "${count}"
      OK=$((OK + 1))
      return
    fi
  done

  printf '\033[1;31m  [fail] %-32s\033[0m HEC POST OK but search did not find event_id=%s within 30s\n' \
    "${label}" "${event_id}"
  FAIL=$((FAIL + 1))
}

# ---------------------------------------------------------------------------
# Per-token verifications.
# ---------------------------------------------------------------------------

log "HEC verification target: ${HEC_TARGET}"
log "Splunk REST target:      ${SPLUNK_REST}"
log ""

log "1) OTel collector token (main, _internal, itsi_im_metrics, nwpay_audit, nwpay_infra)"
verify "main / otel-token"        "${TOKEN_OTEL}" "main"        "verify:logs:smoke"
verify "nwpay_infra / otel-token" "${TOKEN_OTEL}" "nwpay_infra" "verify:logs:smoke"
verify "nwpay_audit / otel-token" "${TOKEN_OTEL}" "nwpay_audit" "verify:logs:smoke"

log ""
log "2) Scripts token (nwpay_audit only)"
verify "nwpay_audit / scripts-token" "${TOKEN_SCRIPTS}" "nwpay_audit" "verify:logs:smoke"

log ""
log "3) Firehose token (aws_* indexes only). WARN expected if Tier 3 not yet enabled."
verify "aws_cloudtrail / firehose-token" "${TOKEN_FIREHOSE}" "aws_cloudtrail" "verify:logs:smoke"
verify "aws_vpcflow / firehose-token"    "${TOKEN_FIREHOSE}" "aws_vpcflow"    "verify:logs:smoke"
verify "aws_guardduty / firehose-token"  "${TOKEN_FIREHOSE}" "aws_guardduty"  "verify:logs:smoke"
verify "aws_eks_audit / firehose-token"  "${TOKEN_FIREHOSE}" "aws_eks_audit"  "verify:logs:smoke"

log ""
log "4) Allow-list policing - the firehose token MUST be rejected by main."
if [[ -n "${TOKEN_FIREHOSE}" && "${TOKEN_FIREHOSE}" != "null" ]]; then
  rejected_code="$(post_event "${TOKEN_FIREHOSE}" "main" "verify:logs:reject" "should-be-rejected")"
  if [[ "${rejected_code}" == "200" ]]; then
    printf '\033[1;31m  [fail] %-32s\033[0m firehose token wrote into main (allow-list breach)\n' "main / firehose-token"
    FAIL=$((FAIL + 1))
  else
    printf '\033[1;32m  [ok]   %-32s\033[0m firehose token rejected (HTTP %s)\n' "main / firehose-token" "${rejected_code}"
    OK=$((OK + 1))
  fi
fi

log ""
log "5) Infra container logs (search-back only; no synthetic HEC inject)"
if (( QUICK )); then
  log "   skipped (--quick)"
else
  probe_infra_logs "postgresql / nwpay_infra" 'index=nwpay_infra sourcetype=postgresql'
  probe_infra_logs "redis / nwpay_infra"       'index=nwpay_infra sourcetype=redis'
  probe_infra_logs "kafka / nwpay_infra"        'index=nwpay_infra sourcetype=kafka'
  probe_infra_logs "postgres:dbm / nwpay_infra" 'index=nwpay_infra sourcetype=postgres:dbm'
fi

log ""
log "Summary: OK=${OK}  WARN=${WARN}  FAIL=${FAIL}"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
