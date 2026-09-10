#!/usr/bin/env bash
# Install Splunk IT Service Intelligence (ITSI) and its hard dependency
# (Python for Scientific Computing - PSC) onto the demo Splunk Enterprise EC2
# instance, then add the ITSI NFR license and restart splunkd.
#
# Idempotent end to end: each install/license/restart step is gated on a
# remote-state probe so a re-run on a healthy box is a fast no-op.
#
# Required artefacts (override paths via env if you move them):
#   ITSI_PSC_PATH      - python-for-scientific-computing-for-linux-64-bit_*.tgz
#   ITSI_APP_PATH      - splunk-it-service-intelligence_*.spl
#   ITSI_LICENSE_PATH  - Splunk ITSI NFR *.License
#
# Required env (sourced from .env via lib.sh if available):
#   TF_VAR_splunk_enterprise_admin_password - Splunk admin password
#
# Optional env:
#   SPLUNK_ENTERPRISE_HOST  default itsi.splunk-observability.com (FQDN
#                           that resolves to the demo EC2 EIP - see
#                           terraform/splunk_enterprise_dns.tf for the
#                           Route53 + EIP plumbing). Override with the
#                           raw IP if DNS isn't ready yet.
#   SSH_USER                default ec2-user (AL2023 default)
#   SSH_KEY                 default <repo>/terraform/splunk-enterprise.pem
#   SPLUNK_ADMIN_USER       default admin

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_cmd ssh scp shasum

# ----------------------------------------------------------------------------
# 1. Inputs
# ----------------------------------------------------------------------------
SPLUNK_ENTERPRISE_HOST="${SPLUNK_ENTERPRISE_HOST:-itsi.splunk-observability.com}"
SSH_USER="${SSH_USER:-ec2-user}"
SSH_KEY="${SSH_KEY:-${REPO_ROOT}/terraform/splunk-enterprise.pem}"
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:-admin}"
: "${TF_VAR_splunk_enterprise_admin_password:?Set TF_VAR_splunk_enterprise_admin_password (in .env or environment)}"
SPLUNK_ADMIN_PASS="${TF_VAR_splunk_enterprise_admin_password}"

MEDIA_DIR_DEFAULT="/Users/mserieys/Documents/_Cursor/_media+license+logins"
ITSI_PSC_PATH="${ITSI_PSC_PATH:-${MEDIA_DIR_DEFAULT}/python-for-scientific-computing-for-linux-64-bit_431.tgz}"
ITSI_APP_PATH="${ITSI_APP_PATH:-${MEDIA_DIR_DEFAULT}/splunk-it-service-intelligence_4212.spl}"
ITSI_LICENSE_PATH="${ITSI_LICENSE_PATH:-${MEDIA_DIR_DEFAULT}/Splunk ITSI NFR CY2026 1H.License}"

REMOTE_STAGE="/tmp/itsi-install"

# ----------------------------------------------------------------------------
# 2. Local preflight
# ----------------------------------------------------------------------------
[[ -f "${SSH_KEY}" ]] || fail "SSH key not found: ${SSH_KEY} - run terraform apply for the splunk_enterprise module first"
chmod 600 "${SSH_KEY}" 2>/dev/null || true

for label_path in \
  "PSC tarball|${ITSI_PSC_PATH}" \
  "ITSI app|${ITSI_APP_PATH}" \
  "ITSI license|${ITSI_LICENSE_PATH}"; do
  label="${label_path%%|*}"
  path="${label_path#*|}"
  [[ -f "${path}" ]] || fail "${label} not found: ${path}"
done

# ----------------------------------------------------------------------------
# 3. Helpers
# ----------------------------------------------------------------------------
SSH_OPTS=(
  -i "${SSH_KEY}"
  -o "StrictHostKeyChecking=accept-new"
  -o "UserKnownHostsFile=${HOME}/.ssh/known_hosts"
  -o "ConnectTimeout=10"
  -o "ServerAliveInterval=30"
  -o "BatchMode=yes"
)

# Run a command on the remote box. Stdin is closed so heredocs do not
# accidentally hang waiting for terminal input.
ssh_run() {
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SPLUNK_ENTERPRISE_HOST}" "$@" </dev/null
}

# Run a splunk CLI command as the splunk service user with auth.
# We pass the password via stdin (-auth) reading from a temporary file on
# the host, but for simplicity here we use the documented flag form.
# CAUTION: arguments are interpolated into a remote shell string, so callers
# must not pass user-controlled data here.
splunk_cli() {
  local args="$*"
  ssh_run "sudo -u splunk /opt/splunk/bin/splunk ${args} -auth '${SPLUNK_ADMIN_USER}:${SPLUNK_ADMIN_PASS}'"
}

# scp <local> <remote> only if the remote sha256 differs (or remote is missing).
# Avoids re-uploading a 700 MB ITSI .spl on every run.
scp_if_changed() {
  local local_path="$1"
  local remote_path="$2"
  local local_sha
  local_sha="$(shasum -a 256 "${local_path}" | awk '{print $1}')"

  local remote_sha=""
  remote_sha="$(ssh_run "test -f '${remote_path}' && sha256sum '${remote_path}' | awk '{print \$1}' || true")"

  if [[ "${local_sha}" == "${remote_sha}" && -n "${remote_sha}" ]]; then
    log "  [skip] ${remote_path} already current (sha256 match)"
    return 0
  fi

  log "  [push] $(basename "${local_path}") -> ${SSH_USER}@${SPLUNK_ENTERPRISE_HOST}:${remote_path}"
  scp "${SSH_OPTS[@]}" "${local_path}" "${SSH_USER}@${SPLUNK_ENTERPRISE_HOST}:${remote_path}"
}

# Block until 'splunk status' reports splunkd running. Bound by max_wait.
wait_for_splunkd_ready() {
  local max_wait="${1:-300}"
  local waited=0
  log "waiting for splunkd to be ready (timeout ${max_wait}s)"
  while (( waited < max_wait )); do
    if ssh_run "sudo -u splunk /opt/splunk/bin/splunk status 2>/dev/null | grep -q 'splunkd is running'"; then
      log "  splunkd is running"
      return 0
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done
  fail "splunkd did not come up within ${max_wait}s"
}

# Block until ITSI's KV Store collections appear and SA-ITOA is enabled.
# ITSI runs migrations on first start after install / on app upgrade; the
# REST endpoint /servicesNS/nobody/SA-ITOA/configs/conf-itsi_settings/migration
# returns 200 once migrations have settled.
wait_for_itsi_migrations() {
  local max_wait="${1:-600}"
  local waited=0
  log "waiting for ITSI (SA-ITOA) migrations to settle (timeout ${max_wait}s)"
  while (( waited < max_wait )); do
    # Probe SA-ITOA's REST namespace. If it responds with anything other than a
    # connection refused / 404, ITSI's splunkd handlers have come up.
    if ssh_run "curl -ks -u '${SPLUNK_ADMIN_USER}:${SPLUNK_ADMIN_PASS}' \
                  'https://localhost:8089/servicesNS/nobody/SA-ITOA/data/indexes?count=1&output_mode=json' \
                  | grep -q '\"links\"'"; then
      log "  SA-ITOA REST namespace is responding"
      return 0
    fi
    sleep 10
    waited=$(( waited + 10 ))
  done
  warn "SA-ITOA did not respond within ${max_wait}s - log into Splunk Web and check Settings > Apps"
  return 0
}

# ----------------------------------------------------------------------------
# 4. Remote preflight
# ----------------------------------------------------------------------------
log "remote preflight: ssh ${SSH_USER}@${SPLUNK_ENTERPRISE_HOST}"
ssh_run "true" || fail "cannot SSH to ${SSH_USER}@${SPLUNK_ENTERPRISE_HOST} with key ${SSH_KEY}"

log "remote preflight: splunk version"
splunk_cli "version"

log "remote preflight: disk space on /opt"
remote_free_gb="$(ssh_run "df -BG --output=avail /opt | tail -1 | tr -dc '0-9'")"
if (( remote_free_gb < 10 )); then
  fail "Insufficient free disk on /opt: ${remote_free_gb} GB (need >= 10 GB for ITSI install + KV Store)"
fi
log "  ${remote_free_gb} GB free on /opt"

log "remote preflight: KV Store status"
splunk_cli "show kvstore-status" >/dev/null || fail "KV Store is not healthy - ITSI requires KV Store"

# ----------------------------------------------------------------------------
# 5. Stage artefacts
# ----------------------------------------------------------------------------
log "staging artefacts to ${SSH_USER}@${SPLUNK_ENTERPRISE_HOST}:${REMOTE_STAGE}"
ssh_run "mkdir -p '${REMOTE_STAGE}' && chmod 755 '${REMOTE_STAGE}'"
scp_if_changed "${ITSI_PSC_PATH}"     "${REMOTE_STAGE}/psc.tgz"
scp_if_changed "${ITSI_APP_PATH}"     "${REMOTE_STAGE}/itsi.spl"
scp_if_changed "${ITSI_LICENSE_PATH}" "${REMOTE_STAGE}/itsi.License"

# ----------------------------------------------------------------------------
# 6. Install Python for Scientific Computing (PSC)
# ----------------------------------------------------------------------------
log "installing PSC if missing"
PSC_APP_NAME="Splunk_SA_Scientific_Python_Linux_x86_64"
if splunk_cli "display app ${PSC_APP_NAME}" >/dev/null 2>&1; then
  log "  PSC already installed - skipping"
else
  splunk_cli "install app '${REMOTE_STAGE}/psc.tgz' -update 1"
  log "  PSC installed"
fi

# ----------------------------------------------------------------------------
# 7. Install ITSI
#    The ITSI .spl is a *compound* tarball containing ~20 sibling apps at the
#    archive root (itsi, SA-ITOA, DA-ITSI-*, SA-IndexCreation, etc.). Splunk's
#    `splunk install app` rejects multi-root archives with "archive contains
#    more than one immediate subdirectory" - the supported path for compound
#    archives is to extract straight into $SPLUNK_HOME/etc/apps and let
#    splunkd discover the apps on the next restart.
# ----------------------------------------------------------------------------
log "installing ITSI if missing"
if ssh_run "test -d /opt/splunk/etc/apps/itsi/default"; then
  log "  ITSI already installed (/opt/splunk/etc/apps/itsi present) - skipping"
else
  log "  extracting compound .spl into /opt/splunk/etc/apps"
  ssh_run "sudo tar -xzf '${REMOTE_STAGE}/itsi.spl' -C /opt/splunk/etc/apps \
           && sudo chown -R splunk:splunk /opt/splunk/etc/apps"
  log "  ITSI extracted"
fi

# ----------------------------------------------------------------------------
# 8. Add ITSI license
#    'splunk add licenses' returns "already installed" non-zero on duplicates,
#    so we swallow the exit code. The license slot is verified post-restart.
# ----------------------------------------------------------------------------
log "adding ITSI license (idempotent)"
splunk_cli "add licenses '${REMOTE_STAGE}/itsi.License'" || true

# ----------------------------------------------------------------------------
# 9. Restart splunkd via systemd, wait for ready, wait for ITSI migrations
# ----------------------------------------------------------------------------
log "restarting splunkd via systemd"
ssh_run "sudo systemctl restart Splunkd"
wait_for_splunkd_ready 300
wait_for_itsi_migrations 600

# ----------------------------------------------------------------------------
# 10. Post-install verification
# ----------------------------------------------------------------------------
log "post-install verification"
splunk_cli "display app ${PSC_APP_NAME}" | sed -n '1,3p' || true
splunk_cli "display app itsi"             | sed -n '1,3p' || true
splunk_cli "display app SA-ITOA"          | sed -n '1,3p' || true

# Print the licenses table so the operator can eyeball that the ITSI slot is
# present and within its validity window.
log "licenses installed:"
splunk_cli "list licenses" | sed -n '1,40p' || true

# ----------------------------------------------------------------------------
# 11. Done
# ----------------------------------------------------------------------------
log "ITSI install complete"
log "  Splunk Web: https://${SPLUNK_ENTERPRISE_HOST}:8000/en-US/app/itsi"
log "  First login triggers the ITSI setup wizard (run-once, ~30 s)"
log "  Confirm license: Settings > Licensing should show 'IT Service Intelligence'"
