#!/usr/bin/env bash
#
# scripts/09b-create-te-streams.sh
#
# Creates the ThousandEyes Cloud Streaming integrations that push test
# data into Splunk HEC (the manual click-through "step C" from
# scripts/09-configure-splunk-te-inputs.sh). Drives /v7/stream end-to-end
# via the ThousandEyes v7 API so no browser interaction is required.
#
# What it does:
#   1. Reads secrets/thousandeyes.env (TE_OAUTH_BEARER_TOKEN +
#      TE_ACCOUNT_GROUP_ID) and secrets/te-state.json (HEC tokens + test
#      IDs from earlier scripts).
#   2. Probes the public HEC endpoint to confirm it serves a browser-
#      trusted certificate. ThousandEyes Cloud rejects integration
#      creation against self-signed certs with "TLS/SSL issue", so this
#      preflight fails fast with an actionable error if the Let's Encrypt
#      cert (scripts/00d-install-letsencrypt-hec.sh) has not been
#      installed yet.
#   3. For each (signal, hec-token-name) pair below it upserts a /v7/stream
#      integration:
#         signal=metric -> te-stream-metrics  -> sourcetype=cisco:thousandeyes:path-vis
#         signal=trace  -> te-stream-traces   -> sourcetype=cisco:thousandeyes:trace
#      Each stream is bound to all six TE tests (TE-01..TE-06) via
#      testMatch[]. Tests are referenced by id with domain=cea (Cloud
#      and Enterprise Agents).
#   4. Writes the resulting stream IDs into secrets/te-state.json under
#      .splunk.streams[<token-name>] = {streamId, signal} so re-runs PUT
#      to update rather than POST to create.
#
# Why only metric + trace (and not alerts / activity):
#   The /v7/stream API exposes signal=metric|trace|log only. The Alerts
#   and Activity logs Streams use separate, web-only configuration
#   surfaces in ThousandEyes - they are not reachable via this API. The
#   ITSI Digital Customer Experience tier KPIs only depend on path-vis
#   (metric) and trace data, so creating those two streams is sufficient
#   to flip every DCE KPI from Unknown/N/A to a real value.
#
# Idempotent: GETs /v7/stream first, finds an existing entry by
# streamEndpointUrl + signal, and PUTs an update; only POSTs if no
# match exists. Re-running after a successful first run is a no-op.
#
# Required env (from secrets/thousandeyes.env):
#   TE_OAUTH_BEARER_TOKEN   v7 bearer token (preferred)
#   TE_API_BASE             default https://api.thousandeyes.com
#   TE_ACCOUNT_GROUP_ID     numeric account group ID
#
# Required state (from secrets/te-state.json):
#   .splunk.hecEndpoint                              HEC URL with port
#   .splunk.hecTokens["te-stream-metrics"].token     metrics HEC token
#   .splunk.hecTokens["te-stream-traces"].token      traces  HEC token
#   .TE-01-http-spa.testId .. .TE-06-dns-server.testId
#
# Exit codes:
#   0  success or idempotent no-op
#   1  precondition failure (missing env / state / HEC TLS issue)
#   2  TE API rejected one or more requests; details in the error block

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_cmd curl jq openssl

ENV_FILE="${REPO_ROOT}/secrets/thousandeyes.env"
STATE_FILE="${STATE_FILE:-${REPO_ROOT}/secrets/te-state.json}"

if [[ ! -f "${ENV_FILE}" ]]; then
  fail "missing ${ENV_FILE} (run scripts/08-configure-thousandeyes.sh first)"
fi
# shellcheck disable=SC1090
set -a; source "${ENV_FILE}"; set +a

: "${TE_API_BASE:=https://api.thousandeyes.com}"
: "${TE_ACCOUNT_GROUP_ID:?TE_ACCOUNT_GROUP_ID must be set in ${ENV_FILE}}"
if [[ -z "${TE_OAUTH_BEARER_TOKEN:-}" ]]; then
  fail "TE_OAUTH_BEARER_TOKEN not set in ${ENV_FILE}; v6 Basic Auth is not supported on /v7/stream"
fi

if [[ ! -f "${STATE_FILE}" ]]; then
  fail "missing ${STATE_FILE} (run scripts/08 + scripts/09 first)"
fi

# --- 1. Pull the things we need from te-state.json -------------------------
HEC_ENDPOINT="$(jq -r '.splunk.hecEndpoint // empty' "${STATE_FILE}")"
HEC_HOST="$(jq -r '.splunk.host // empty' "${STATE_FILE}")"
HEC_TOKEN_METRICS="$(jq -r '.splunk.hecTokens["te-stream-metrics"].token // empty' "${STATE_FILE}")"
HEC_TOKEN_TRACES="$(jq -r '.splunk.hecTokens["te-stream-traces"].token // empty' "${STATE_FILE}")"

[[ -n "${HEC_ENDPOINT}" ]] || fail "te-state.json has no .splunk.hecEndpoint (run scripts/09)"
[[ -n "${HEC_HOST}" ]]     || fail "te-state.json has no .splunk.host (run scripts/09)"
[[ -n "${HEC_TOKEN_METRICS}" && -n "${HEC_TOKEN_TRACES}" ]] \
  || fail "te-state.json missing splunk.hecTokens entries (run scripts/09)"

# Test IDs for the six demo tests.
TEST_IDS=()
for k in TE-01-http-spa TE-02-http-api TE-03-pageload-spa TE-04-transaction-payment TE-05-api-post-process TE-06-dns-server; do
  id="$(jq -r --arg k "${k}" '.[$k].testId // empty' "${STATE_FILE}")"
  if [[ -z "${id}" || "${id}" == "null" ]]; then
    fail "te-state.json missing .${k}.testId (run scripts/08-configure-thousandeyes.sh first)"
  fi
  TEST_IDS+=("${id}")
done
log "binding metric stream to ${#TEST_IDS[@]} tests: ${TEST_IDS[*]}"

# Trace streams only accept tests that produce trace spans. The TE v7 API
# rejects http-server / dns-server / agent-to-server etc. with
# "Invalid tests: CEA-..." when bound to a trace stream. Only page-load
# (TE-03) and web-transactions (TE-04) tests in our six produce traces.
TRACE_TEST_IDS=()
for k in TE-03-pageload-spa TE-04-transaction-payment; do
  id="$(jq -r --arg k "${k}" '.[$k].testId // empty' "${STATE_FILE}")"
  if [[ -n "${id}" && "${id}" != "null" ]]; then
    TRACE_TEST_IDS+=("${id}")
  fi
done
log "binding trace stream to ${#TRACE_TEST_IDS[@]} tests: ${TRACE_TEST_IDS[*]}"

# --- 2. Preflight: HEC must serve a browser-trusted cert -------------------
# ThousandEyes Cloud explicitly probes streamEndpointUrl during the create
# call and rejects self-signed certs. Catch that here with a clear error
# instead of a confusing 400 from /v7/stream.
log "probing HEC TLS at ${HEC_HOST}:8088"
HEC_ISSUER="$(echo | openssl s_client -connect "${HEC_HOST}:8088" \
                -servername "${HEC_HOST}" 2>/dev/null \
              | openssl x509 -noout -issuer 2>/dev/null \
              | sed 's/^issuer= //')"
if [[ -z "${HEC_ISSUER}" ]]; then
  fail "could not retrieve HEC TLS cert from ${HEC_HOST}:8088 (firewall? Splunk down?)"
fi
log "  issuer: ${HEC_ISSUER}"
if echo "${HEC_ISSUER}" | grep -qiE 'SplunkServerDefault|SplunkCommonCA'; then
  warn "HEC is still serving Splunk's default self-signed certificate."
  warn "ThousandEyes Cloud will reject the streaming integration with 'TLS/SSL issue'."
  warn "Run scripts/00d-install-letsencrypt-hec.sh first, then re-run this script."
  exit 1
fi

# --- 3. te_curl helper ------------------------------------------------------
te_curl() {
  local method="$1"; shift
  local path="$1"; shift
  local body_file="${1:-}"
  local sep="?"
  [[ "${path}" == *"?"* ]] && sep="&"
  local url="${TE_API_BASE}${path}${sep}aid=${TE_ACCOUNT_GROUP_ID}"

  local tmp; tmp="$(mktemp -t te-stream-resp.XXXXXX)"
  local args=(-sS -o "${tmp}" -w '%{http_code}'
              -X "${method}"
              -H "Authorization: Bearer ${TE_OAUTH_BEARER_TOKEN}"
              -H "Content-Type: application/json"
              -H "Accept: application/json")
  [[ -n "${body_file}" ]] && args+=(--data-binary "@${body_file}")

  local code
  code=$(curl "${args[@]}" "${url}" || echo "000")
  cat "${tmp}"
  printf '\n' >&2
  printf 'te_curl %s %s -> HTTP %s\n' "${method}" "${path}" "${code}" >&2
  rm -f "${tmp}"
  if [[ "${code}" =~ ^5 ]]; then
    return 1
  fi
  return 0
}

# --- 4. Build per-signal testMatch JSON ------------------------------------
# Each entry is {id: "<numeric-id-as-string>", domain: "cea"} (cea = Cloud
# and Enterprise Agents). The API accepts the testIds as either string or
# integer; we keep them as strings for stability across jq versions.
metric_test_match_json="$(jq -nc \
  --argjson ids "$(printf '%s\n' "${TEST_IDS[@]}" | jq -R . | jq -s .)" \
  '[$ids[] | {id: ., domain: "cea"}]')"
trace_test_match_json="$(jq -nc \
  --argjson ids "$(printf '%s\n' "${TRACE_TEST_IDS[@]:-}" | jq -R . | jq -s 'map(select(length>0))')" \
  '[$ids[] | {id: ., domain: "cea"}]')"

# --- 5. Upsert one stream per (signal, token) pair -------------------------
# The HEC URL must include the /event path; /v7/stream rejects bare
# /services/collector with 4xx because the Cisco TA expects events JSON
# rather than the raw text endpoint.
hec_url_event="${HEC_ENDPOINT%/}"
[[ "${hec_url_event}" == */services/collector ]] && hec_url_event="${hec_url_event}/event"

# Existing streams (one GET, parsed twice).
existing_streams_json="$(te_curl GET /v7/stream 2>/dev/null)"

upsert_stream() {
  local signal="$1"
  local token_name="$2"
  local hec_token="$3"
  local sourcetype="$4"
  local test_match_json="$5"

  log "upserting stream signal=${signal} -> ${token_name} (sourcetype=${sourcetype})"

  # /v7/stream is the "ThousandEyes for OpenTelemetry" API. For
  # type=splunk-hec the HEC token belongs in exporterConfig.splunkHec.token,
  # NOT in customHeaders.Authorization (the v6 streaming API used the
  # latter; v7 OTel does not). source/sourceType/index are emitted in each
  # OTLP event so we set them explicitly to match what the Cisco
  # ThousandEyes Splunk Add-on / ITSI KPI base searches expect, rather
  # than relying on the HEC token's defaults.
  local body_file
  body_file="$(mktemp -t te-stream-body.XXXXXX)"
  jq -n \
    --arg signal "${signal}" \
    --arg url "${hec_url_event}" \
    --arg token "${hec_token}" \
    --arg src "ThousandEyesOTel" \
    --arg srctype "${sourcetype}" \
    --arg index "thousandeyes" \
    --argjson tests "${test_match_json}" \
    '{
       type: "splunk-hec",
       endpointType: "http",
       signal: $signal,
       dataModelVersion: "v2",
       streamEndpointUrl: $url,
       exporterConfig: {
         splunkHec: {
           token: $token,
           source: $src,
           sourceType: $srctype,
           index: $index
         }
       },
       testMatch: $tests,
       enabled: true
     }' > "${body_file}"

  # Idempotency: match by streamEndpointUrl + signal. ThousandEyes
  # streams are unique per (URL, signal) per account group from a usage
  # standpoint, so this is the safest dedup key.
  local existing_id
  existing_id="$(echo "${existing_streams_json}" | jq -r \
    --arg url "${hec_url_event}" \
    --arg signal "${signal}" \
    '.[] | select(.streamEndpointUrl==$url and .signal==$signal) | .id' \
    | head -1)"

  local resp
  if [[ -n "${existing_id}" && "${existing_id}" != "null" ]]; then
    log "  PUT existing streamId=${existing_id}"
    resp="$(te_curl PUT "/v7/stream/${existing_id}" "${body_file}")"
    stream_id="${existing_id}"
  else
    log "  POST new (no match in ${TE_API_BASE}/v7/stream)"
    resp="$(te_curl POST "/v7/stream" "${body_file}")"
    stream_id="$(echo "${resp}" | jq -r '.id // empty')"
  fi
  rm -f "${body_file}"

  if [[ -z "${stream_id}" || "${stream_id}" == "null" ]]; then
    echo "${resp}" | jq -C '.' 2>/dev/null || echo "${resp}"
    fail "  stream upsert for ${token_name} did not return an id"
  fi
  log "  ok streamId=${stream_id}"

  # Persist into te-state.json under .splunk.streams[<token-name>].
  local tmp_state; tmp_state="$(mktemp -t te-state.XXXXXX)"
  jq --arg name "${token_name}" \
     --arg sid  "${stream_id}" \
     --arg sig  "${signal}" \
     '.splunk.streams[$name] = {streamId: $sid, signal: $sig}' \
    "${STATE_FILE}" > "${tmp_state}"
  mv "${tmp_state}" "${STATE_FILE}"
}

upsert_stream "metric" "te-stream-metrics" "${HEC_TOKEN_METRICS}" "cisco:thousandeyes:path-vis" "${metric_test_match_json}"
if [[ ${#TRACE_TEST_IDS[@]} -gt 0 ]]; then
  upsert_stream "trace" "te-stream-traces" "${HEC_TOKEN_TRACES}" "cisco:thousandeyes:trace" "${trace_test_match_json}"
else
  warn "no page-load / web-transactions tests configured; skipping trace stream"
fi

log "all streams upserted; te-state.json updated:"
jq '.splunk.streams' "${STATE_FILE}"

cat <<'NEXT'

Next:
  - Wait ~1-5 minutes for ThousandEyes' first push.
  - Verify on Splunk Web (operator workstation, since 8089 is CIDR-locked):
        index=thousandeyes earliest=-15m | stats count by sourcetype, testName
    Expect rows like:
        cisco:thousandeyes:path-vis  NatWest Payments - SPA login page         N
        cisco:thousandeyes:trace     NatWest Payments - SPA login page-load    N
        cisco:thousandeyes:trace     NatWest Payments - end-to-end ...         N
  - Open ITSI: Service Analyzer -> Digital Customer Experience.
    The 7 KPIs should flip from Unknown/N/A to real values within
    one alert period (60 s).

Note: the Alerts and Activity log streams (te-stream-alerts,
te-stream-activity) are NOT created by this script - the v7 /stream API
does not expose those signal types. The DCE tier KPIs do not depend on
them; they are wired separately via Alert Rules webhooks if needed.
NEXT
