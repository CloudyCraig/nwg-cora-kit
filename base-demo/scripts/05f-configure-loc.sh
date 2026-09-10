#!/usr/bin/env bash
# Wire Splunk Enterprise <-> Splunk Observability Log Observer Connect (LOC).
#
# Enterprise side:
#   * Ensures lo-connect user + lo_connect role (indexes: main, splunkrum,
#     nwpay_infra) via scripts/lib/bootstrap_loc_user.sh on the EC2 box.
#   * Requires splunkd :8089 to present a CN-matching cert (run
#     scripts/00d-install-letsencrypt-hec.sh once if LOC save fails on cert).
#
# Observability side:
#   * PUTs the existing SplunkEnterprise integration (id GhVhuhqAIAA in the
#     eu0 demo org) with domain, lo-connect credentials, and SplunkCommonCA.
#   * Uses the ingest token from the cluster secret (same token class that
#     can list /v2/integration in this tenant).
#
# Usage:
#   scripts/05f-configure-loc.sh
#   LOC_PASSWORD='...' scripts/05f-configure-loc.sh   # non-default lo-connect pass

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_cmd ssh scp curl jq kubectl terraform

SPLUNK_ENTERPRISE_HOST="${SPLUNK_ENTERPRISE_HOST:-itsi.splunk-observability.com}"
SSH_USER="${SSH_USER:-ec2-user}"
SSH_KEY="${SSH_KEY:-${REPO_ROOT}/terraform/splunk-enterprise.pem}"
SSH_KEY="$(ensure_splunk_ssh_key "${SSH_KEY}")"
chmod 600 "${SSH_KEY}" 2>/dev/null || true

: "${TF_VAR_splunk_enterprise_admin_password:?Set TF_VAR_splunk_enterprise_admin_password}"
LOC_PASSWORD="${LOC_PASSWORD:-lo-connect-demo-pass}"
SPLUNK_REALM="${SPLUNK_REALM:-eu0}"
LOC_INTEGRATION_ID="${LOC_INTEGRATION_ID:-GhVhuhqAIAA}"

ssh_run() {
  ssh -i "${SSH_KEY}" \
      -o StrictHostKeyChecking=accept-new \
      -o BatchMode=yes \
      "${SSH_USER}@${SPLUNK_ENTERPRISE_HOST}" "$@"
}

log "1/3 Bootstrap lo-connect user + role on ${SPLUNK_ENTERPRISE_HOST}"
scp -i "${SSH_KEY}" -o StrictHostKeyChecking=accept-new \
  "${SCRIPT_DIR}/lib/bootstrap_loc_user.sh" \
  "${SSH_USER}@${SPLUNK_ENTERPRISE_HOST}:/tmp/bootstrap_loc_user.sh"
ssh_run "sudo ADMIN_PASSWORD='${TF_VAR_splunk_enterprise_admin_password}' \
  LOC_PASSWORD='${LOC_PASSWORD}' bash /tmp/bootstrap_loc_user.sh"

log "2/3 Verify lo-connect can authenticate on public :8089"
code="$(curl -sk -o /dev/null -w '%{http_code}' \
  -u "lo-connect:${LOC_PASSWORD}" \
  "https://${SPLUNK_ENTERPRISE_HOST}:8089/services/authorization/tokens?output_mode=json&count=1")"
[[ "${code}" == "200" ]] || fail "lo-connect auth on :8089 returned HTTP ${code} (expected 200)"

log "3/3 Update Splunk Observability LOC integration ${LOC_INTEGRATION_ID}"
API_TOKEN="${SPLUNK_API_TOKEN:-${TF_VAR_splunk_api_token:-}}"
if [[ -z "${API_TOKEN}" ]]; then
  API_TOKEN="$(kubectl -n "${COLLECTOR_NAMESPACE}" get secret splunk-access-token \
    -o jsonpath='{.data.splunk_observability_access_token}' 2>/dev/null | base64 -d || true)"
  USING_INGEST=1
else
  USING_INGEST=0
fi
[[ -n "${API_TOKEN}" ]] || fail "no API token available (set SPLUNK_API_TOKEN or TF_VAR_splunk_api_token)"

CACERT="$(ssh_run 'sudo cat /opt/splunk/etc/auth/cacert.pem')"
[[ -n "${CACERT}" ]] || fail "could not read SplunkCommonCA from ${SPLUNK_ENTERPRISE_HOST}"

PAYLOAD="$(jq -nc \
  --arg name "lo-connect" \
  --arg type "SplunkEnterprise" \
  --arg domain "https://${SPLUNK_ENTERPRISE_HOST}:8089" \
  --arg username "lo-connect" \
  --arg password "${LOC_PASSWORD}" \
  --arg certificate "${CACERT}" \
  '{name:$name,type:$type,enabled:true,domain:$domain,username:$username,password:$password,certificate:$certificate}')"

resp="$(curl -sk -w '\n%{http_code}' \
  -X PUT \
  -H "X-SF-Token: ${API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}" \
  "https://api.${SPLUNK_REALM}.signalfx.com/v2/integration/${LOC_INTEGRATION_ID}")"
http="$(printf '%s' "${resp}" | tail -1)"
body="$(printf '%s' "${resp}" | sed '$d')"
if [[ "${http}" != "200" ]]; then
  printf '%s\n' "${body}" >&2
  if [[ "${http}" == "403" && "${USING_INGEST}" == "1" ]]; then
    CERT_FILE="${REPO_ROOT}/.loc-splunk-common-ca.pem"
    printf '%s\n' "${CACERT}" > "${CERT_FILE}"
    chmod 600 "${CERT_FILE}"
    warn "ingest token cannot PUT integrations (HTTP 403)."
    warn "Enterprise side is ready. Finish in Splunk Observability UI:"
    warn "  Logs -> Logs connections -> lo-connect -> edit/re-save"
    warn "  Splunk URL:     https://${SPLUNK_ENTERPRISE_HOST}:8089"
    warn "  Username:       lo-connect"
    warn "  Password:       ${LOC_PASSWORD}"
    warn "  Certificate:    ${CERT_FILE}  (SplunkCommonCA - paste full PEM)"
    warn "  Indexes:        main, nwpay_infra  (+ splunkrum when that index exists)"
    warn "Or re-run with an Observability *admin* API token:"
    warn "  SPLUNK_API_TOKEN=... scripts/05f-configure-loc.sh"
    exit 0
  fi
  fail "LOC integration PUT returned HTTP ${http}"
fi

enabled="$(printf '%s' "${body}" | jq -r '.enabled // false')"
domain="$(printf '%s' "${body}" | jq -r '.domain // empty')"
log "LOC integration updated: enabled=${enabled} domain=${domain}"

log "verify: list federated indexes visible to lo_connect"
indexes="$(curl -sk -u "lo-connect:${LOC_PASSWORD}" \
  "https://${SPLUNK_ENTERPRISE_HOST}:8089/services/data/indexes?output_mode=json&count=0" \
  | jq -r '[.entry[].name] | map(select(. == "main" or . == "splunkrum" or . == "nwpay_infra")) | join(",")')"
log "  lo_connect can see: ${indexes:-<none of main,splunkrum,nwpay_infra>}"

log "done. In Splunk Observability: Logs -> Logs connections -> lo-connect should be active."
log "  Test: APM trace -> Logs for this trace, or Logs Explorer index filter main / nwpay_infra."

unset LOC_PASSWORD API_TOKEN CACERT PAYLOAD resp
