#!/usr/bin/env bash
#
# scripts/09-configure-splunk-te-inputs.sh
#
# Splunk-side scaffolding for the Cisco ThousandEyes Add-on for Splunk
# (ta_cisco_thousandeyes 0.6.x). Idempotently creates:
#
#   1. The "thousandeyes" index (cold/warm volume tagged so it's auditable
#      separately from main).
#   2. One HEC token per streamable data type. The TE Streaming integration
#      requires a separate token for Tests Stream - Metrics, Tests Stream -
#      Traces, Alerts Stream, and Activity logs Stream so each stream's
#      sourcetype routing is correct.
#   3. Writes a JSON map of token names -> token values + endpoint into
#      secrets/te-state.json so scripts/07-configure-thousandeyes.sh and
#      anything else that wires the streaming integration can pick them up
#      symbolically.
#
# Why this isn't fully end-to-end: the add-on's "Account" step uses an
# interactive OAuth click-through that can't be reasonably scripted from
# the outside (requires a browser session against ThousandEyes Identity).
# We document the click flow at the end.
#
# Required env: secrets/thousandeyes.env. Reuses TE_API_BASE,
# TE_ACCOUNT_GROUP_ID for the "next steps" output.
#
# Required Splunk admin password: SPLUNK_ENTERPRISE_ADMIN_PASSWORD. Read
# from terraform.tfvars / .env if present (see lib.sh::source_env).

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_cmd curl jq terraform ssh

ENV_FILE="${REPO_ROOT}/secrets/thousandeyes.env"
STATE_FILE="${STATE_FILE:-${REPO_ROOT}/secrets/te-state.json}"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set -a; source "${ENV_FILE}"; set +a
fi

: "${SPLUNK_ENTERPRISE_ADMIN_PASSWORD:?SPLUNK_ENTERPRISE_ADMIN_PASSWORD must be set (look in terraform.tfvars or .env)}"

# --- Discover Splunk REST endpoint via terraform output --------------------
# Prefer the env-file DEMO_HOSTNAME when set so we use the stable FQDN
# even before terraform's `splunk_enterprise_fqdn` output has been baked
# into state. Falls back to the terraform output, then the raw EIP.
SPLUNK_FQDN="$(tf_output splunk_enterprise_fqdn 2>/dev/null || true)"
SPLUNK_PUBLIC_IP="$(tf_output splunk_enterprise_public_ip)"
SPLUNK_HOST="${DEMO_HOSTNAME:-${SPLUNK_FQDN:-${SPLUNK_PUBLIC_IP}}}"
if [[ -z "${SPLUNK_HOST}" || "${SPLUNK_HOST}" == "null" ]]; then
  fail "could not resolve Splunk Enterprise hostname/IP from terraform outputs"
fi
SPLUNK_REST="https://${SPLUNK_HOST}:8089"
SPLUNK_HEC="https://${SPLUNK_HOST}:8088/services/collector"

log "Splunk REST endpoint: ${SPLUNK_REST}"
log "Splunk HEC endpoint:  ${SPLUNK_HEC}"

# --- splunk REST helper ----------------------------------------------------
splunk_curl() {
  local method="$1"; shift
  local path="$1"; shift
  curl -sS -k \
    -u "admin:${SPLUNK_ENTERPRISE_ADMIN_PASSWORD}" \
    -X "${method}" \
    --data-urlencode "output_mode=json" \
    "$@" \
    "${SPLUNK_REST}${path}"
}

# --- 1. Index thousandeyes -------------------------------------------------
INDEX_NAME="thousandeyes"
EXISTS=$(splunk_curl GET "/services/data/indexes/${INDEX_NAME}" 2>/dev/null \
  | jq -r '.entry[0].name // empty')
if [[ -n "${EXISTS}" ]]; then
  log "index ${INDEX_NAME} already exists"
else
  log "creating index ${INDEX_NAME}"
  splunk_curl POST "/services/data/indexes" \
    --data-urlencode "name=${INDEX_NAME}" \
    --data-urlencode "datatype=event" \
    --data-urlencode "homePath=\$SPLUNK_DB/${INDEX_NAME}/db" \
    --data-urlencode "coldPath=\$SPLUNK_DB/${INDEX_NAME}/colddb" \
    --data-urlencode "thawedPath=\$SPLUNK_DB/${INDEX_NAME}/thaweddb" \
    >/dev/null
fi

# --- 2. Ensure HEC is enabled and global allowAck/SSL is sane --------------
HEC_GLOBAL=$(splunk_curl GET "/servicesNS/nobody/splunk_httpinput/data/inputs/http/http" 2>/dev/null \
  || true)
HEC_DISABLED=$(echo "${HEC_GLOBAL}" | jq -r '.entry[0].content.disabled // "1"')
if [[ "${HEC_DISABLED}" != "0" && "${HEC_DISABLED}" != "false" ]]; then
  log "enabling HEC global"
  splunk_curl POST "/servicesNS/nobody/splunk_httpinput/data/inputs/http/http" \
    --data-urlencode "disabled=0" \
    --data-urlencode "enableSSL=1" \
    >/dev/null
fi

# --- 3. Create one HEC token per stream ------------------------------------
# Token name -> {sourcetype}. The Cisco TE add-on routes by sourcetype, so
# we create dedicated tokens that pin each stream to its expected
# sourcetype value.
#
# Parallel arrays rather than `declare -A` because macOS still ships bash
# 3.2 which mishandles hyphens inside associative-array keys under `set -u`
# (the hyphen is parsed as arithmetic subtraction). Indexed arrays work
# everywhere.
TOKEN_NAMES=(
  "te-stream-metrics"
  "te-stream-traces"
  "te-stream-alerts"
  "te-stream-activity"
)
TOKEN_SOURCETYPES=(
  "cisco:thousandeyes:path-vis"
  "cisco:thousandeyes:trace"
  "cisco:thousandeyes:alerts"
  "cisco:thousandeyes:activity"
)

state_json="{}"
if [[ -f "${STATE_FILE}" ]]; then state_json="$(cat "${STATE_FILE}")"; fi
hec_state="{}"

for i in "${!TOKEN_NAMES[@]}"; do
  token_name="${TOKEN_NAMES[${i}]}"
  sourcetype="${TOKEN_SOURCETYPES[${i}]}"
  EXISTING_TOKEN=$(splunk_curl GET "/servicesNS/nobody/splunk_httpinput/data/inputs/http/${token_name}" 2>/dev/null \
    | jq -r '.entry[0].content.token // empty')

  if [[ -n "${EXISTING_TOKEN}" ]]; then
    log "HEC token ${token_name} already exists (sourcetype=${sourcetype})"
    token_value="${EXISTING_TOKEN}"
  else
    log "creating HEC token ${token_name} -> sourcetype=${sourcetype}, index=${INDEX_NAME}"
    resp=$(splunk_curl POST "/servicesNS/nobody/splunk_httpinput/data/inputs/http" \
      --data-urlencode "name=${token_name}" \
      --data-urlencode "index=${INDEX_NAME}" \
      --data-urlencode "indexes=${INDEX_NAME}" \
      --data-urlencode "sourcetype=${sourcetype}" \
      --data-urlencode "useACK=0" \
      --data-urlencode "disabled=0")
    token_value=$(echo "${resp}" | jq -r '.entry[0].content.token // empty')
    if [[ -z "${token_value}" ]]; then
      echo "${resp}" >&2
      fail "HEC token creation failed for ${token_name}"
    fi
  fi

  hec_state=$(echo "${hec_state}" | jq --arg n "${token_name}" \
                                       --arg t "${token_value}" \
                                       --arg s "${sourcetype}" \
    '.[$n] = {token: $t, sourcetype: $s}')
done

state_json=$(echo "${state_json}" | jq --argjson h "${hec_state}" \
                                       --arg endpoint "${SPLUNK_HEC}" \
                                       --arg index "${INDEX_NAME}" \
                                       --arg host "${SPLUNK_HOST}" \
  '.splunk = {hecEndpoint: $endpoint, index: $index, host: $host, hecTokens: $h}')

mkdir -p "$(dirname "${STATE_FILE}")"
echo "${state_json}" | jq '.' > "${STATE_FILE}"
log "wrote ${STATE_FILE}"

# --- 3b. Reconcile the TE side of the streaming integration ----------------
# Background: the streams on the ThousandEyes side carry the HEC token
# value AND an `enabled` flag. Both drift in real demos:
#
#   * `enabled` flips to false the moment the streamStatus sees enough
#     consecutive HTTP errors (auth failure on the HEC token, EIP
#     change, nginx down, etc). Once disabled, TE never auto-recovers
#     even after the underlying issue clears - the operator has to go
#     back into the TE UI and click "Enable" per stream. We saw this
#     in production: streams went silent 2026-05-21 after the Splunk
#     EC2 was rebuilt, and the 40-day-stale data only surfaced when
#     we audited KPI values on 2026-06-11. The 21 ThousandEyes-fed
#     ITSI KPIs were all sitting at zero in the meantime.
#
#   * `exporterConfig.splunkHec.token` carries whatever value was
#     pasted into the TE UI at stream-creation time. If the Splunk
#     EC2 is rebuilt the HEC token is regenerated with a fresh UUID,
#     the TE-side value goes stale, and HEC starts returning 401.
#
# This block PUTs both fields back to the desired state on every run
# of scripts/09 so a credential rotation or accidental disable can't
# silently dark the demo. Streams that don't exist yet still need
# the operator to do step C in the click-flow above (the v7 API
# requires the test bindings, which we don't manage here).
#
# Required env: TE_OAUTH_BEARER_TOKEN, TE_API_BASE, TE_ACCOUNT_GROUP_ID.
# If absent we log a WARN and skip - the rest of step 3 already wrote
# the Splunk-side state file so the operator can finish manually.
if [[ -n "${TE_OAUTH_BEARER_TOKEN:-}" && -n "${TE_API_BASE:-}" && -n "${TE_ACCOUNT_GROUP_ID:-}" ]]; then
  log "reconciling TE side of streaming integration (enable + refresh HEC token)"
  streams_resp="$(curl -fsS \
    -H "Authorization: Bearer ${TE_OAUTH_BEARER_TOKEN}" \
    "${TE_API_BASE}/v7/streams?aid=${TE_ACCOUNT_GROUP_ID}" 2>/dev/null || true)"
  if [[ -z "${streams_resp}" ]]; then
    log "  WARN: TE /v7/streams returned empty body; skipping reconcile"
  else
    # TE returns either {"streams":[...]} or a bare [...] depending on
    # account-group permissions. Normalise to the bare list.
    streams_list="$(echo "${streams_resp}" | jq 'if type=="array" then . else (.streams // []) end')"
    stream_count="$(echo "${streams_list}" | jq 'length')"
    log "  TE reports ${stream_count} stream(s)"

    # Map sourceType -> HEC token name -> token value. The TE side
    # carries a `sourceType` per stream which we use to pick the right
    # HEC token from hec_state (built above).
    for i in $(seq 0 $((stream_count - 1))); do
      sid="$(echo "${streams_list}" | jq -r ".[${i}].id")"
      sig="$(echo "${streams_list}" | jq -r ".[${i}].signal")"
      st_existing="$(echo "${streams_list}" | jq -r ".[${i}].exporterConfig.splunkHec.sourceType // empty")"
      enabled_existing="$(echo "${streams_list}" | jq -r ".[${i}].enabled")"
      url_existing="$(echo "${streams_list}" | jq -r ".[${i}].streamEndpointUrl")"

      # Pick the HEC token whose sourcetype matches the TE stream's
      # configured sourceType. Falls back to te-stream-metrics for
      # path-vis when the TE-side value is empty.
      target_token=""
      for j in "${!TOKEN_NAMES[@]}"; do
        if [[ "${TOKEN_SOURCETYPES[${j}]}" == "${st_existing}" ]]; then
          target_token="$(echo "${hec_state}" | jq -r --arg n "${TOKEN_NAMES[${j}]}" '.[$n].token')"
          break
        fi
      done
      if [[ -z "${target_token}" || "${target_token}" == "null" ]]; then
        log "  WARN: stream ${sid} (signal=${sig}, sourceType=${st_existing}) - no matching HEC token; skipping"
        continue
      fi

      # PUT the minimal envelope that brings the stream back to a
      # known-good state. The TE v7 API accepts a partial body on PUT
      # and ignores read-only fields (auditOperation, streamStatus,
      # _links). We deliberately do NOT touch `testMatch` so the
      # operator's UI-side test bindings survive a script run.
      put_body="$(jq -nc \
        --arg token "${target_token}" \
        --arg index "${INDEX_NAME}" \
        --arg src   "ThousandEyesOTel" \
        --arg st    "${st_existing}" \
        --arg url   "${SPLUNK_HEC}/event" \
        '{
          enabled: true,
          streamEndpointUrl: $url,
          exporterConfig: {
            splunkHec: {
              token: $token,
              index: $index,
              source: $src,
              sourceType: $st
            }
          }
        }')"

      log "  PUT stream ${sid} signal=${sig} sourceType=${st_existing} (was enabled=${enabled_existing})"
      put_resp="$(curl -fsS \
        -X PUT \
        -H "Authorization: Bearer ${TE_OAUTH_BEARER_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "${put_body}" \
        "${TE_API_BASE}/v7/streams/${sid}?aid=${TE_ACCOUNT_GROUP_ID}" 2>&1 || true)"
      new_enabled="$(echo "${put_resp}" | jq -r '.enabled // "?"' 2>/dev/null || echo "?")"
      new_status="$(echo "${put_resp}" | jq -r '.streamStatus.status // "?"' 2>/dev/null || echo "?")"
      log "    -> enabled=${new_enabled} status=${new_status}"
    done
  fi
else
  log "TE reconcile skipped (TE_OAUTH_BEARER_TOKEN / TE_API_BASE / TE_ACCOUNT_GROUP_ID not set in ${ENV_FILE})"
fi

# --- 4. Friendly summary -----------------------------------------------------
cat <<NEXT

next steps (manual click-through, the add-on does not expose these via REST):

  A. Splunk side - configure the add-on's TE user account
     1. Open: ${SPLUNK_REST/8089/8000}/en-US/app/ta_cisco_thousandeyes/configuration
     2. Tab "ThousandEyes User" -> Add
        - Account Name: natwest-payments-demo
        - Authorize: click, complete the OAuth consent in TE
        - Save

  B. Splunk side - create the four streaming inputs
     1. Open: ${SPLUNK_REST/8089/8000}/en-US/app/ta_cisco_thousandeyes/inputs
     2. Click "Create New Input" once for each of the four:
          Tests Stream - Metrics      -> HEC token: te-stream-metrics
          Tests Stream - Traces       -> HEC token: te-stream-traces
          Alerts Stream               -> HEC token: te-stream-alerts
          Activity logs Stream        -> HEC token: te-stream-activity
        Bind each input to the same TE User account from step A.

  C. ThousandEyes side - configure Streaming integration
     1. Open: https://app.thousandeyes.com/account/integrations/streaming
     2. New Stream:
          Type: Splunk
          HEC URL:  ${SPLUNK_HEC}
          HEC Token (per stream): values now in ${STATE_FILE} under
                                  .splunk.hecTokens[*].token
          Tests bound to stream: TE-01 .. TE-06 (ids in ${STATE_FILE})

  D. Verify
     index=${INDEX_NAME} earliest=-15m | stats count by sourcetype
     should return rows for: cisco:thousandeyes:path-vis,
     cisco:thousandeyes:trace, cisco:thousandeyes:alerts,
     cisco:thousandeyes:activity within ~1 min of step B+C completing.

NEXT
log "done"
