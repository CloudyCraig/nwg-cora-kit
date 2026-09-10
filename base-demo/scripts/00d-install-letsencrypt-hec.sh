#!/usr/bin/env bash
#
# scripts/00d-install-letsencrypt-hec.sh
#
# One-shot driver to install (or refresh) a Let's Encrypt certificate for
# the Splunk Enterprise HEC listener on the *currently running* EC2
# instance. Use this when terraform's ignore_changes=[user_data]
# lifecycle clause has prevented the cloud-init template change from
# taking effect.
#
# What it does:
#   1. Validates that the SSH key + admin password env vars are present.
#   2. Confirms tcp/80 inbound is open from the public internet (the
#      Let's Encrypt HTTP-01 challenge needs this; already opened by the
#      public SPA proxy SG rule splunk_public_http in
#      terraform/public_spa_proxy.tf, so no additional terraform apply
#      is required when var.public_spa_proxy_enabled = true).
#   3. SCPs scripts/lib/install_letsencrypt_hec.sh onto the box.
#   4. Runs it as root via sudo, exporting FQDN + EMAIL.
#   5. Verifies the public HEC port now serves a Let's Encrypt cert.
#
# Why this is separate from cloud-init:
#   The Splunk EC2 instance is declared with
#     lifecycle { ignore_changes = [user_data] }
#   so cloud-init template edits do not trigger a redeploy. This script
#   provides the "do it now on the running box" path while keeping the
#   cloud-init template authoritative for fresh deploys.
#
# Required env (sourced from .env via lib.sh):
#   TF_VAR_splunk_enterprise_admin_password  - Splunk admin password
#   LETSENCRYPT_ADMIN_EMAIL                  - optional, contact address
#                                              for renewal warnings
#   SPLUNK_ENTERPRISE_HOST                   - default: itsi.splunk-observability.com
#
# Idempotent: re-runs only renew when <30 days remain on the cert.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_cmd ssh scp curl openssl

SPLUNK_ENTERPRISE_HOST="${SPLUNK_ENTERPRISE_HOST:-itsi.splunk-observability.com}"
SSH_USER="${SSH_USER:-ec2-user}"
SSH_KEY="${SSH_KEY:-${REPO_ROOT}/terraform/splunk-enterprise.pem}"
LETSENCRYPT_ADMIN_EMAIL="${LETSENCRYPT_ADMIN_EMAIL:-}"
LIB_SCRIPT="${REPO_ROOT}/scripts/lib/install_letsencrypt_hec.sh"

[[ -f "${SSH_KEY}" ]] || fail "SSH key not found at ${SSH_KEY}"
[[ -f "${LIB_SCRIPT}" ]] || fail "missing ${LIB_SCRIPT}"

# --- Preflight: tcp/80 must be reachable so Let's Encrypt's HTTP-01 ---------
# challenge can complete. The public SPA proxy SG rule
# (terraform/public_spa_proxy.tf::splunk_public_http) opens this when
# var.public_spa_proxy_enabled = true. If tcp/80 is closed certbot will
# fail with "connection refused" after a long timeout - bail early.
log "probing tcp/80 inbound on ${SPLUNK_ENTERPRISE_HOST}"
if ! nc -z -w 5 "${SPLUNK_ENTERPRISE_HOST}" 80 >/dev/null 2>&1; then
  warn "tcp/80 not reachable on ${SPLUNK_ENTERPRISE_HOST}."
  warn "Ensure terraform has been applied with var.public_spa_proxy_enabled=true."
  warn "Continuing anyway in case the probe is wrong; certbot will fail clearly."
fi

# --- Probe current HEC cert (so we can show the before/after) ---------------
log "current HEC cert on ${SPLUNK_ENTERPRISE_HOST}:8088 (before):"
( echo | openssl s_client -connect "${SPLUNK_ENTERPRISE_HOST}:8088" \
       -servername "${SPLUNK_ENTERPRISE_HOST}" 2>/dev/null \
  | openssl x509 -noout -subject -issuer 2>/dev/null \
  | sed 's/^/    /' ) || warn "could not retrieve current HEC cert"

# --- Stage script onto the box ----------------------------------------------
log "copying installer to ${SSH_USER}@${SPLUNK_ENTERPRISE_HOST}:/tmp/"
scp -i "${SSH_KEY}" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=15 \
    "${LIB_SCRIPT}" \
    "${SSH_USER}@${SPLUNK_ENTERPRISE_HOST}:/tmp/install_letsencrypt_hec.sh"

# --- Execute ----------------------------------------------------------------
log "running installer as root on ${SPLUNK_ENTERPRISE_HOST} (FQDN=${SPLUNK_ENTERPRISE_HOST})"
# We export FQDN and EMAIL via the remote shell so the installer reads
# them. sudo -E preserves the env. Use a here-doc to chain sudo cleanly
# while still failing fast on a non-zero exit.
ssh -i "${SSH_KEY}" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=15 \
    "${SSH_USER}@${SPLUNK_ENTERPRISE_HOST}" bash -se <<REMOTE
set -Eeuo pipefail
chmod 0750 /tmp/install_letsencrypt_hec.sh
sudo \
  FQDN='${SPLUNK_ENTERPRISE_HOST}' \
  EMAIL='${LETSENCRYPT_ADMIN_EMAIL}' \
  bash /tmp/install_letsencrypt_hec.sh
rm -f /tmp/install_letsencrypt_hec.sh
REMOTE

# --- Verify ----------------------------------------------------------------
log "verifying HEC TLS now serves a Let's Encrypt cert (give splunkd ~10s to restart)"
sleep 10
for i in 1 2 3 4 5 6; do
  ISSUER="$(echo | openssl s_client -connect "${SPLUNK_ENTERPRISE_HOST}:8088" \
              -servername "${SPLUNK_ENTERPRISE_HOST}" 2>/dev/null \
            | openssl x509 -noout -issuer 2>/dev/null \
            | sed 's/^issuer= //')"
  if echo "${ISSUER}" | grep -qiE "let's encrypt|/CN=R[0-9]"; then
    log "HEC now serves a Let's Encrypt-issued cert:"
    echo "    ${ISSUER}"
    log "next: bash scripts/09b-create-te-streams.sh to create the four TE streams."
    exit 0
  fi
  log "  attempt ${i}: issuer=\"${ISSUER:-unknown}\" - waiting for splunkd..."
  sleep 5
done

fail "HEC cert did not flip to Let's Encrypt within 40s. Check /var/log/splunk-bootstrap.log and /var/log/letsencrypt/letsencrypt.log on the box."
