#!/usr/bin/env bash
#
# scripts/10-extend-itsi-with-te.sh
#
# Bootstraps the Digital Customer Experience (L2 nwpay_l2_dce) tier in
# ITSI. The DCE tier is purely synthetic - it sources its 7 KPIs from
# ThousandEyes data flowing into index=thousandeyes via the Cisco
# ThousandEyes Add-on for Splunk.
#
# What it does:
#   1. Validates that secrets/te-state.json contains Splunk-side wiring
#      (HEC tokens / index) - i.e. that scripts/09 was run.
#   2. (Soft) checks that index=thousandeyes has data within the last
#      24h. Warns if not, but doesn't block - ITSI happily creates KPIs
#      with "no data" until the streaming integration starts pushing.
#   3. Re-runs scripts/07-itsi-bootstrap.sh which picks up the new
#      kbs_te_* base searches and the nwpay_l2_dce service we appended
#      to itsi/service-tree.yaml.
#   4. Verifies the DCE service appears in the ITSI REST API.
#
# Why this isn't just `re-run 07-itsi-bootstrap.sh`: the DCE tier
# depends on operator-completed click-through (configure the TE user
# account in Splunk + the Streaming integration in TE Cloud). This
# wrapper makes that ordering explicit and enforces the precondition.
#
# Required env: SPLUNK_ENTERPRISE_HOST (defaults to itsi.splunk-...),
# TF_VAR_splunk_enterprise_admin_password.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_cmd ssh curl jq

SPLUNK_ENTERPRISE_HOST="${SPLUNK_ENTERPRISE_HOST:-itsi.splunk-observability.com}"
SSH_USER="${SSH_USER:-ec2-user}"
SSH_KEY="${SSH_KEY:-${REPO_ROOT}/terraform/splunk-enterprise.pem}"
SPLUNK_MGMT_PORT="${SPLUNK_MGMT_PORT:-8089}"
LOCAL_PORT="${LOCAL_PORT:-18089}"
STATE_FILE="${STATE_FILE:-${REPO_ROOT}/secrets/te-state.json}"

: "${TF_VAR_splunk_enterprise_admin_password:?TF_VAR_splunk_enterprise_admin_password must be set}"
SPLUNK_ADMIN_PASS="${TF_VAR_splunk_enterprise_admin_password}"

# --- 1. Preconditions -------------------------------------------------------
if [[ ! -f "${STATE_FILE}" ]]; then
  fail "${STATE_FILE} missing - run scripts/09-configure-splunk-te-inputs.sh first"
fi
if ! jq -e '.splunk.hecTokens["te-stream-metrics"].token' "${STATE_FILE}" >/dev/null 2>&1; then
  fail "${STATE_FILE} missing splunk.hecTokens block - re-run scripts/09-configure-splunk-te-inputs.sh"
fi
log "preconditions ok: te-state.json has Splunk HEC plumbing"

# --- 2. Probe index=thousandeyes for recent data ---------------------------
# Uses the Splunk REST search/jobs/export endpoint via SSH-tunnel-free
# https-on-public-mgmt isn't an option (8089 is operator-CIDR-only), so
# we do a simple SSH tunnel for the duration of the probe.
TUNNEL_PID=""
trap '[[ -n "${TUNNEL_PID}" ]] && kill "${TUNNEL_PID}" 2>/dev/null || true' EXIT

log "opening short-lived SSH tunnel 127.0.0.1:${LOCAL_PORT} -> ${SPLUNK_ENTERPRISE_HOST}:${SPLUNK_MGMT_PORT}"
ssh -i "${SSH_KEY}" \
  -o "StrictHostKeyChecking=accept-new" \
  -o "ConnectTimeout=10" \
  -L "${LOCAL_PORT}:127.0.0.1:${SPLUNK_MGMT_PORT}" \
  -fN \
  "${SSH_USER}@${SPLUNK_ENTERPRISE_HOST}"
TUNNEL_PID="$(pgrep -f "ssh.*-L ${LOCAL_PORT}:127.0.0.1:${SPLUNK_MGMT_PORT}.*${SSH_USER}@${SPLUNK_ENTERPRISE_HOST}" | head -1 || true)"

# Soft-probe: rows in last 24h, by sourcetype.
PROBE_RESULT=$(curl -sS -k \
  -u "admin:${SPLUNK_ADMIN_PASS}" \
  --data-urlencode 'output_mode=json' \
  --data-urlencode 'search=search index=thousandeyes earliest=-24h | stats count by sourcetype' \
  --data-urlencode 'exec_mode=oneshot' \
  "https://127.0.0.1:${LOCAL_PORT}/services/search/jobs/export" 2>/dev/null \
  | jq -c 'select(.result) | .result' || true)

if [[ -z "${PROBE_RESULT}" ]]; then
  log "WARN  index=thousandeyes returned 0 rows in last 24h"
  log "      DCE KPIs will create OK but show 'no data' until either:"
  log "        - TE Streaming integration is wired (see scripts/09 output)"
  log "        - or Cisco TE add-on pushes its first poll (~1-5 min after"
  log "          the 'ThousandEyes User' OAuth flow completes in Splunk Web)"
else
  log "index=thousandeyes data probe OK:"
  echo "${PROBE_RESULT}" | jq -r '"  " + .sourcetype + "  count=" + (.count|tostring)'
fi

# --- 3. Re-run the existing bootstrap, which will pick up the appended ---
#       nwpay_l2_dce service + kbs_te_* base searches in service-tree.yaml.
log "running scripts/07-itsi-bootstrap.sh to apply the DCE tier"
bash "${SCRIPT_DIR}/07-itsi-bootstrap.sh"

# --- 4. Verify ------------------------------------------------------------
log "verifying nwpay_l2_dce service is present in ITSI"
# itoa_interface treats `/service/<x>` as fetch-by-title. To look up by
# _key we have to use the list endpoint with a filter parameter.
DCE_KEY=$(curl -sS -k -G \
  -u "admin:${SPLUNK_ADMIN_PASS}" \
  --data-urlencode 'output_mode=json' \
  --data-urlencode 'filter={"_key":"nwpay_l2_dce"}' \
  "https://127.0.0.1:${LOCAL_PORT}/servicesNS/nobody/SA-ITOA/itoa_interface/service" \
  | jq -r '.[0]._key // empty')

if [[ "${DCE_KEY}" != "nwpay_l2_dce" ]]; then
  fail "nwpay_l2_dce was not created in ITSI - check the 07 bootstrap output"
fi

log "DCE tier present in ITSI (_key=${DCE_KEY})"
log "open: https://${SPLUNK_ENTERPRISE_HOST}:8000/en-US/app/itsi/service_analyzer"
log "      then drill into 'Digital Customer Experience' under NatWest Card Payments"
