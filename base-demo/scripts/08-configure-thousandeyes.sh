#!/usr/bin/env bash
#
# scripts/08-configure-thousandeyes.sh
#
# Idempotently provisions the six demo ThousandEyes tests via the v7 REST
# API and writes their IDs into secrets/te-state.json so downstream
# scripts (Splunk inputs, ITSI KPIs, slide notes) can refer to them
# symbolically.
#
# What it does:
#   1. Loads secrets/thousandeyes.env (rotated token, account group ID,
#      demo hostname, transaction creds).
#   2. Probes the auth path (Bearer first, falls back to v6 Basic Auth).
#   3. Selects 5 cloud agents in London / Frankfurt / Amsterdam / NYC /
#      Singapore so the geographic narrative matches the demo storyline.
#   4. For each test in scripts/lib/te_test_payloads/:
#       * envsubst's the template into a payload
#       * looks up the existing test by name (tests are listed by AID)
#       * POSTs new tests, PUTs updates - keeping IDs stable across re-runs
#       * pins the rendered payload + response into secrets/te-state.json
#   5. Prints a short table of "what's now in TE" with each test's id and
#      type. Re-running the script with the same env file is safe and
#      produces no churn.
#
# Required env (sourced from secrets/thousandeyes.env):
#   TE_OAUTH_BEARER_TOKEN  preferred v7 token; or
#   TE_API_EMAIL + TE_API_TOKEN  v6 Basic Auth fallback
#   TE_API_BASE            default https://api.thousandeyes.com
#   TE_ACCOUNT_GROUP_ID    numeric AID
#   DEMO_HOSTNAME, DEMO_BASE_URL
#   TE_TX_USERNAME, TE_TX_PASSWORD  (TE-04 only)
#
# Re-run this script after:
#   - Rotating the token in secrets/thousandeyes.env
#   - Editing any payload under scripts/lib/te_test_payloads/
#   - Standing up a new TE Account Group
#   - Adding/removing agents in the cloud-agent allow-list below
#
# Exit codes:
#   0  success or no-op
#   1  precondition failure (missing env, broken auth, no agents found)
#   2  TE API rejected one or more payloads - see the error block printed

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_cmd curl jq python3

ENV_FILE="${REPO_ROOT}/secrets/thousandeyes.env"
PAYLOAD_DIR="${SCRIPT_DIR}/lib/te_test_payloads"
STATE_DIR="${REPO_ROOT}/secrets"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/te-state.json}"

# Cloud-agent location names we want to use, in priority order. The first
# agent matching each location is selected; if a location has no cloud
# agent in the operator's account group it gets dropped (so the test is
# created with however many agents we found).
DESIRED_LOCATIONS=(
  "London"
  "Frankfurt"
  "Amsterdam"
  "New York"
  "Singapore"
)

# --- Load env file ---------------------------------------------------------
if [[ ! -f "${ENV_FILE}" ]]; then
  fail "missing ${ENV_FILE}. Copy from secrets/thousandeyes.env.example and fill in the gaps."
fi
# shellcheck disable=SC1090
set -a; source "${ENV_FILE}"; set +a

: "${TE_API_BASE:=https://api.thousandeyes.com}"
: "${DEMO_HOSTNAME:?DEMO_HOSTNAME must be set in ${ENV_FILE}}"
: "${DEMO_BASE_URL:?DEMO_BASE_URL must be set in ${ENV_FILE}}"
: "${TE_ACCOUNT_GROUP_ID:?TE_ACCOUNT_GROUP_ID must be set in ${ENV_FILE}}"

if [[ -z "${TE_OAUTH_BEARER_TOKEN:-}" && -z "${TE_API_TOKEN:-}" ]]; then
  fail "no auth in ${ENV_FILE}: set TE_OAUTH_BEARER_TOKEN (preferred) or TE_API_EMAIL+TE_API_TOKEN"
fi

# --- Auth helper -----------------------------------------------------------
# Wraps curl with the right auth headers regardless of v7 or v6, and pipes
# AID through ?aid=. Echoes status code on stderr, body on stdout. Fails
# the script on 5xx; 4xx is left to the caller (404 is normal during
# "does this test already exist" lookups).
te_curl() {
  local method="$1"; shift
  local path="$1"; shift
  local body_file="${1:-}"
  local sep="?"
  if [[ "${path}" == *"?"* ]]; then sep="&"; fi
  local url="${TE_API_BASE}${path}${sep}aid=${TE_ACCOUNT_GROUP_ID}"

  local hdrs=(-H "Accept: application/json" -H "Content-Type: application/json")
  local auth=()
  if [[ -n "${TE_OAUTH_BEARER_TOKEN:-}" ]]; then
    auth=(-H "Authorization: Bearer ${TE_OAUTH_BEARER_TOKEN}")
  else
    auth=(-u "${TE_API_EMAIL}:${TE_API_TOKEN}")
  fi

  local tmp; tmp="$(mktemp -t te-resp.XXXXXX)"
  trap 'rm -f "${tmp}"' RETURN
  local args=(-sS -o "${tmp}" -w '%{http_code}' -X "${method}" "${hdrs[@]}" "${auth[@]}")
  if [[ -n "${body_file}" ]]; then
    args+=(--data-binary "@${body_file}")
  fi
  local code
  code=$(curl "${args[@]}" "${url}" || true)
  cat "${tmp}"
  echo "" >&2
  echo "te_curl ${method} ${path} -> HTTP ${code}" >&2
  if [[ "${code}" -ge 500 ]]; then
    fail "TE API ${method} ${path} returned 5xx; aborting"
  fi
  return 0
}

# --- Probe auth ------------------------------------------------------------
log "probing auth at ${TE_API_BASE}/v7/account-groups (aid=${TE_ACCOUNT_GROUP_ID})"
PROBE="$(te_curl GET /v7/account-groups 2>/dev/null || true)"
if ! echo "${PROBE}" | jq -e '.accountGroups' >/dev/null 2>&1; then
  echo "${PROBE}" | head -c 400 >&2; echo "" >&2
  fail "auth probe failed; check TE_OAUTH_BEARER_TOKEN / TE_API_EMAIL / TE_API_TOKEN / TE_API_BASE in ${ENV_FILE}"
fi
log "auth ok ($(echo "${PROBE}" | jq '.accountGroups | length') account group(s) visible)"

# --- Discover cloud agents -------------------------------------------------
log "selecting cloud agents in: ${DESIRED_LOCATIONS[*]}"
AGENTS_JSON="$(te_curl GET /v7/agents)"
# Build an array of {id, name, location} for cloud agents
ALL_CLOUD_AGENTS="$(echo "${AGENTS_JSON}" | jq '[.agents[] | select(.agentType=="cloud") | {id: .agentId, name: .agentName, location: .location}]')"

picked_ids=()
for loc in "${DESIRED_LOCATIONS[@]}"; do
  match="$(echo "${ALL_CLOUD_AGENTS}" | jq -r --arg loc "${loc}" '[.[] | select(.location | contains($loc))] | first | (.id // empty)')"
  if [[ -n "${match}" ]]; then
    picked_ids+=("${match}")
    log "  + ${loc} -> agentId ${match}"
  else
    log "  - ${loc} no cloud agent found, skipping"
  fi
done

if [[ ${#picked_ids[@]} -eq 0 ]]; then
  fail "no cloud agents found in any desired location; widen DESIRED_LOCATIONS or check the account group permissions"
fi

# Build JSON arrays of agent objects for envsubst into the templates.
agent_obj_array() {
  local ids=("$@")
  local out="["
  local first=1
  for id in "${ids[@]}"; do
    if [[ ${first} -eq 1 ]]; then first=0; else out+=","; fi
    out+="{\"agentId\":${id}}"
  done
  out+="]"
  echo "${out}"
}

AGENTS_5_JSON="$(agent_obj_array "${picked_ids[@]:0:5}")"
AGENTS_3_JSON="$(agent_obj_array "${picked_ids[@]:0:3}")"
AGENTS_2_JSON="$(agent_obj_array "${picked_ids[@]:0:2}")"

log "agent allocation:"
log "  AGENTS_5 (HTTP/SPA, DNS):           ${AGENTS_5_JSON}"
log "  AGENTS_3 (HTTP/API, page-load, API): ${AGENTS_3_JSON}"
log "  AGENTS_2 (transaction):              ${AGENTS_2_JSON}"

# --- Helper: list existing tests by name -----------------------------------
existing_test_id_by_name() {
  local name="$1"
  te_curl GET /v7/tests | jq -r --arg n "${name}" '.tests[]? | select(.testName==$n) | .testId' | head -1
}

# --- Helper: ensure a v7 credential exists, return its credentialId -------
# v7 web-transactions tests reference credentials by ID (security.credentials
# resource). We pre-create a credential for the SPA's username/password,
# then inject `credentials: [<id>, <id>]` into the TE-04 payload at runtime.
ensure_credential() {
  local name="$1"
  local value="$2"
  # GET list, find by name
  local existing_id
  existing_id="$(te_curl GET /v7/credentials | jq -r --arg n "${name}" \
    '.credentials[]? | select(.name==$n) | .id' | head -1)"
  if [[ -n "${existing_id}" ]]; then
    echo "${existing_id}"
    return 0
  fi
  # POST create. Body is { name, value }. v7 stores value encrypted; the
  # response only echoes the id + name.
  local body
  body="$(jq -nc --arg n "${name}" --arg v "${value}" '{name:$n, value:$v}')"
  local body_file; body_file="$(mktemp -t te-cred.XXXXXX)"
  trap 'rm -f "${body_file}"' RETURN
  echo "${body}" > "${body_file}"
  local resp
  resp="$(te_curl POST /v7/credentials "${body_file}")"
  local new_id
  new_id="$(echo "${resp}" | jq -r '.id // empty')"
  if [[ -z "${new_id}" ]]; then
    echo "[ensure_credential] failed to create credential '${name}': ${resp}" >&2
    return 1
  fi
  echo "${new_id}"
}

# --- Apply each test -------------------------------------------------------
mkdir -p "${STATE_DIR}"
state="{}"
if [[ -f "${STATE_FILE}" ]]; then state="$(cat "${STATE_FILE}")"; fi

# Map filename -> v7 endpoint suffix per test type. ThousandEyes routes
# different test types to different POST/PUT endpoints under /tests/.
# Parallel arrays rather than associative because macOS still ships
# bash 3.2, which mishandles hyphens inside associative-array keys
# under `set -u`.
PAYLOAD_FILES=(
  "TE-01-http-spa.json"
  "TE-02-http-api.json"
  "TE-03-pageload-spa.json"
  "TE-04-transaction-payment.json"
  "TE-05-api-post-process.json"
  "TE-06-dns-server.json"
)
PAYLOAD_ENDPOINTS=(
  "http-server"
  "http-server"
  "page-load"
  "web-transactions"
  "http-server"
  "dns-server"
)

# --- Pre-create credentials for TE-04 (web-transactions) -------------------
# v7 schema: credentials are independent resources, referenced by ID in
# the test payload. Pre-create them here so the TE-04 render step can
# inject `credentials: [<id>, <id>]` into the JSON body.
log "ensuring TE-04 web-transaction credentials exist"
TE_TX_USERNAME_CRED_ID=""
TE_TX_PASSWORD_CRED_ID=""
if [[ -n "${TE_TX_USERNAME:-}" && -n "${TE_TX_PASSWORD:-}" ]]; then
  TE_TX_USERNAME_CRED_ID="$(ensure_credential 'natwest-payments-tx-username' "${TE_TX_USERNAME}")"
  TE_TX_PASSWORD_CRED_ID="$(ensure_credential 'natwest-payments-tx-password' "${TE_TX_PASSWORD}")"
  log "  username credential id: ${TE_TX_USERNAME_CRED_ID}"
  log "  password credential id: ${TE_TX_PASSWORD_CRED_ID}"
else
  log "  WARN: TE_TX_USERNAME/TE_TX_PASSWORD not set; TE-04 credentials will be empty"
fi
# Build the JSON array we'll splice into TE-04's payload at render time.
TE_TX_CREDENTIALS_JSON="[]"
if [[ -n "${TE_TX_USERNAME_CRED_ID}" && -n "${TE_TX_PASSWORD_CRED_ID}" ]]; then
  TE_TX_CREDENTIALS_JSON="[${TE_TX_USERNAME_CRED_ID},${TE_TX_PASSWORD_CRED_ID}]"
fi

failures=0
for i in "${!PAYLOAD_FILES[@]}"; do
  f="${PAYLOAD_FILES[${i}]}"
  endpoint="${PAYLOAD_ENDPOINTS[${i}]}"
  template="${PAYLOAD_DIR}/${f}"
  if [[ ! -f "${template}" ]]; then
    log "skip ${f}: template not found"
    continue
  fi

  # Render placeholders. Use a Python shim instead of envsubst because
  # macOS doesn't ship envsubst by default and gettext is a heavyweight
  # dependency for what is essentially `${VAR}` -> os.environ[VAR].
  # The shim is conservative: it only touches `${VAR}`-style refs and
  # leaves shell metacharacters / unmatched braces alone.
  rendered="$(mktemp -t te-payload-${f}.XXXXXX)"
  trap 'rm -f "${rendered}"' RETURN
  AGENTS_5="${AGENTS_5_JSON}" \
  AGENTS_3="${AGENTS_3_JSON}" \
  AGENTS_2="${AGENTS_2_JSON}" \
  TE_TEST_RANDOM="$(date +%s | shasum -a 256 | head -c 16)" \
  python3 -c '
import os, re, sys
src = sys.stdin.read()
def repl(m):
    name = m.group(1)
    return os.environ.get(name, m.group(0))
sys.stdout.write(re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", repl, src))
' < "${template}" > "${rendered}"

  # TE-04 web-transactions: splice the pre-created credential IDs into
  # the rendered payload. v7 expects a top-level `credentials` array of
  # integer IDs that resolve to entries in the security.credentials store.
  if [[ "${f}" == "TE-04-transaction-payment.json" && "${TE_TX_CREDENTIALS_JSON}" != "[]" ]]; then
    tmp_with_creds="$(mktemp -t te-payload-creds.XXXXXX)"
    jq --argjson creds "${TE_TX_CREDENTIALS_JSON}" '. + {credentials: $creds}' \
      "${rendered}" > "${tmp_with_creds}"
    mv "${tmp_with_creds}" "${rendered}"
  fi

  test_name="$(jq -r '.testName' "${rendered}")"
  existing_id="$(existing_test_id_by_name "${test_name}" || true)"

  if [[ -n "${existing_id}" && "${existing_id}" != "null" ]]; then
    log "PUT  ${f} -> existing testId=${existing_id} name='${test_name}'"
    resp="$(te_curl PUT "/v7/tests/${endpoint}/${existing_id}" "${rendered}")"
    op="updated"
    test_id="${existing_id}"
  else
    log "POST ${f} (new) name='${test_name}'"
    resp="$(te_curl POST "/v7/tests/${endpoint}" "${rendered}")"
    op="created"
    test_id="$(echo "${resp}" | jq -r '.tests[0].testId // .testId // empty')"
  fi

  if [[ -z "${test_id}" || "${test_id}" == "null" ]]; then
    log "ERROR: ${f} did not produce a testId"
    echo "${resp}" | head -c 600 >&2; echo "" >&2
    failures=$((failures+1))
    continue
  fi

  log "  ${op} testId=${test_id}"
  # Append to state json. Older jq builds don't accept `tonumber?` (the
  # `?` operator can't post-fix a builtin in jq <1.6); use a try/catch
  # pattern that works back to jq 1.5.
  state="$(echo "${state}" | jq --arg key "${f%.json}" --arg id "${test_id}" --arg name "${test_name}" \
            '.[$key] = {testId: (try ($id|tonumber) catch $id), testName: $name}')"
done

echo "${state}" | jq '.' > "${STATE_FILE}"
log "wrote ${STATE_FILE}"

if [[ ${failures} -gt 0 ]]; then
  fail "${failures} test(s) failed to apply; see error blocks above"
fi

log "all six tests applied. summary:"
echo "${state}" | jq -r 'to_entries[] | "  \(.key) \(.value.testId)\t\(.value.testName)"'

log "next: scripts/09-configure-splunk-te-inputs.sh to enable the Splunk add-on inputs and capture the OTLP endpoint URL + token, then bind the streams to these tests in the ThousandEyes UI: Account Settings > Integrations > ThousandEyes Streaming."
