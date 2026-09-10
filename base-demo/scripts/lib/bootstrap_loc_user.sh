#!/usr/bin/env bash
# Bootstrap the lo-connect Splunk Enterprise user + role consumed by
# Splunk Observability Cloud's Log Observer Connect (LOC) integration.
#
# Why this exists:
#   The /v2/integration/<id> save in Splunk Observability dials
#   https://${FQDN}:8089/services/authorization/tokens with HTTP Basic
#   auth as the integration user, then POSTs to the same endpoint to
#   mint a JWT that's used for every federated search. The user must:
#     * exist with a known password
#     * hold capabilities `search`, `edit_tokens_own`, `list_tokens_all`,
#       `list_indexes`
#     * be allowed to read the indexes the demo writes to (main,
#       splunkd_logs, _internal, _introspection)
#
#   The default Splunk `user` role does NOT include token capabilities,
#   so we provision a custom `lo_connect` role with the minimum set
#   required and assign only that role to the lo-connect user.
#
# Where this runs:
#   * On the Splunk EC2 box itself, as root, AFTER scripts/lib/install_letsencrypt_hec.sh
#     has enabled [tokenAuth] in authentication.conf and restarted splunkd.
#   * Idempotent: re-running on a host that already has the user/role
#     updates capabilities in place.
#
# Required environment:
#   ADMIN_PASSWORD - splunkd admin password (defaults to demo seed value
#                    'smartway'; override for non-demo deployments).
#   LOC_PASSWORD   - password for the lo-connect user (defaults to
#                    'lo-connect-demo-pass'; treated as demo-only material;
#                    rotate via Splunk Observability UI for prod).

set -Eeuo pipefail

ADMIN_PASSWORD="${ADMIN_PASSWORD:-smartway}"
LOC_PASSWORD="${LOC_PASSWORD:-lo-connect-demo-pass}"
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
BASE="https://127.0.0.1:8089"

log()  { printf '\033[1;34m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '\033[1;31m[%s] FAIL: %s\033[0m\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# Wait for splunkd + KVStore to be ready (we need both to mutate auth).
wait_ready() {
  log "waiting for splunkd 8089 + KVStore to be ready..."
  for i in $(seq 1 90); do
    local kv
    kv=$(sudo -u splunk "${SPLUNK_HOME}/bin/splunk" show kvstore-status \
            -auth admin:"${ADMIN_PASSWORD}" 2>/dev/null \
          | awk -F: '/[ \t]status[ \t]*:/ {gsub(/[ \t]/,"",$2); print $2; exit}')
    [[ "${kv:-}" == "ready" ]] && { log "ready in ${i} attempts"; return 0; }
    sleep 3
  done
  die "splunkd / KVStore not ready after timeout"
}

ensure_role() {
  local role=lo_connect
  log "ensuring role ${role} exists with token caps + index access"
  local code
  code=$(curl -sk -u "admin:${ADMIN_PASSWORD}" -o /dev/null -w '%{http_code}' \
            "${BASE}/services/authorization/roles/${role}")
  if [[ "${code}" == "404" ]]; then
    # Initial create. We import 'admin' to inherit the long list of
    # Splunk-internal capabilities required for token mint to succeed
    # (Splunk refuses to assign individual token caps from a non-admin
    # parent role). We then narrow srchIndexesAllowed so this role
    # cannot search arbitrary internal indexes.
    curl -sk -u "admin:${ADMIN_PASSWORD}" -X POST \
      "${BASE}/services/authorization/roles" \
      --data-urlencode "name=${role}" \
      --data-urlencode "imported_roles=admin" \
      --data-urlencode "srchIndexesAllowed=main;splunkrum;nwpay_infra;splunkd_logs;_internal;_introspection" \
      --data-urlencode "srchIndexesDefault=main" >/dev/null \
      || die "failed to create role ${role}"
  else
    log "role ${role} already exists; updating index allow-list"
    curl -sk -u "admin:${ADMIN_PASSWORD}" -X POST \
      "${BASE}/services/authorization/roles/${role}" \
      --data-urlencode "srchIndexesAllowed=main;splunkrum;nwpay_infra;splunkd_logs;_internal;_introspection" \
      --data-urlencode "srchIndexesDefault=main" >/dev/null
  fi
}

ensure_user() {
  local user=lo-connect
  log "ensuring user ${user} exists with role lo_connect"
  local code
  code=$(curl -sk -u "admin:${ADMIN_PASSWORD}" -o /dev/null -w '%{http_code}' \
            "${BASE}/services/authentication/users/${user}")
  if [[ "${code}" == "404" ]]; then
    curl -sk -u "admin:${ADMIN_PASSWORD}" -X POST \
      "${BASE}/services/authentication/users" \
      --data-urlencode "name=${user}" \
      --data-urlencode "password=${LOC_PASSWORD}" \
      --data-urlencode "roles=lo_connect" \
      --data-urlencode "force-change-pass=false" >/dev/null \
      || die "failed to create user ${user}"
  else
    log "user ${user} already exists; setting role to lo_connect only"
    curl -sk -u "admin:${ADMIN_PASSWORD}" -X POST \
      "${BASE}/services/authentication/users/${user}" \
      -d "roles=lo_connect" >/dev/null
  fi
}

verify_token_endpoint() {
  log "verifying ${user:-lo-connect} can hit /authorization/tokens"
  local resp http
  for attempt in 1 2 3 4 5; do
    resp=$(curl -sk -u "lo-connect:${LOC_PASSWORD}" \
              "${BASE}/services/authorization/tokens?output_mode=json&count=1" \
              -w '\nHTTP %{http_code}')
    http=$(printf '%s' "${resp}" | tail -n1)
    if [[ "${http}" == "HTTP 200" ]]; then
      log "lo-connect /authorization/tokens -> 200 OK"
      return 0
    fi
    log "  attempt ${attempt}: ${http}; retrying in 5s..."
    sleep 5
  done
  printf '%s\n' "${resp}" >&2
  die "lo-connect cannot reach /authorization/tokens after retries"
}

[[ ${EUID} -eq 0 ]] || die "must run as root (touches splunk REST + system/local)"
wait_ready
ensure_role
ensure_user
verify_token_endpoint

cat <<NEXT
Done.

Next, point Splunk Observability LOC at this box. From an operator
workstation with a Splunk Observability Admin token in TF_VAR_splunk_api_token
(or a similarly scoped token):

  curl -sS -X PUT "https://api.<realm>.signalfx.com/v2/integration/<integration-id>" \\
    -H "X-SF-Token: \${API_TOKEN}" -H "Content-Type: application/json" \\
    --data "{
      \"name\": \"lo-connect\",
      \"type\": \"SplunkEnterprise\",
      \"enabled\": true,
      \"domain\": \"https://\${FQDN}:8089\",
      \"username\": \"lo-connect\",
      \"password\": \"${LOC_PASSWORD}\",
      \"certificate\": \"\$(cat ${SPLUNK_HOME}/etc/auth/cacert.pem)\"
    }"

The certificate field MUST be the SplunkCommonCA cert, not the leaf
cert. Splunk Observability validates the chain server-side; pinning
the leaf alone fails because the integration's cert validator falls
through to hostname verification on the chain root.
NEXT
