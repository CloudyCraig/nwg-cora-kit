#!/usr/bin/env bash
# Install / renew a Let's Encrypt certificate for Splunk HEC (tcp/8088)
# on the Splunk Enterprise EC2 instance.
#
# Why this exists:
#   The Cisco ThousandEyes Streaming integration validates TLS reachability
#   of the HEC endpoint before it lets you save the integration. Splunk's
#   default self-signed cert (CN=SplunkServerDefaultCert) fails that check
#   with "TLS/SSL issue". This script provisions a real, browser-trusted
#   cert from Let's Encrypt and points HEC's [http] stanza at it.
#
# Where this runs:
#   * On the Splunk EC2 box itself (AL2023). Driven either from cloud-init
#     on a fresh deploy, or via scripts/00d-install-letsencrypt-hec.sh
#     SSH'd from an operator workstation onto an existing instance.
#
# Required environment:
#   FQDN     - public hostname that resolves to this instance
#              (e.g. itsi.splunk-observability.com).
#   EMAIL    - admin email for Let's Encrypt account / renewal warnings.
#              Optional; if empty the cert is registered without an email.
#
# Required infrastructure:
#   * Inbound tcp/80 reachable from the public internet (Let's Encrypt
#     HTTP-01 challenge). Already opened by the public SPA proxy SG rule
#     (terraform/public_spa_proxy.tf::splunk_public_http) so this script
#     does NOT need its own SG hole.
#   * Splunk installed at /opt/splunk; the splunk_httpinput app already
#     in place (cloud-init writes its inputs.conf during initial bootstrap).
#   * If nginx (the SPA reverse proxy from scripts/05b-frontend-public-proxy.sh)
#     is running on tcp/80, we briefly stop it for the ACME challenge and
#     start it again afterwards via certbot pre/post-hooks. ~10-20s SPA
#     outage at issue/renewal time, which is acceptable for a demo.
#
# Idempotent: re-running on a host that already has a current cert is a
# fast no-op; certbot's --keep-until-expiring renews only when <30 days
# of validity remain.

set -Eeuo pipefail

FQDN="${FQDN:?FQDN must be set (e.g. itsi.splunk-observability.com)}"
EMAIL="${EMAIL:-}"
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"

# Splunk's HEC [http] stanza wants a single PEM containing the leaf cert,
# the intermediate chain, and the unencrypted private key, in that order.
DEST_PEM="${SPLUNK_HOME}/etc/auth/hec-letsencrypt.pem"

# Override file: a tiny inputs.conf in system/local that adds serverCert
# to the [http] stanza without touching the existing splunk_httpinput
# app. system/local has the highest precedence in Splunk's btool merge
# order, so this reliably wins regardless of app sort order.
OVERRIDE_INPUTS="${SPLUNK_HOME}/etc/system/local/inputs.conf"

# Deploy hook that certbot will invoke after every successful renewal.
# Refreshes the HEC-facing PEM and bounces splunkd so the new key is
# loaded by the [http] listener. The splunkd-host.pem (signed by
# SplunkCommonCA, valid 3y) is independent of LE and not refreshed here.
DEPLOY_HOOK="/usr/local/sbin/splunk-hec-deploy-hook"

log()  { printf '\033[1;34m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[%s] WARN: %s\033[0m\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '\033[1;31m[%s] FAIL: %s\033[0m\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Preconditions.
# ---------------------------------------------------------------------------
[[ "${EUID}" -eq 0 ]] || die "must run as root (certbot --standalone binds tcp/80; writes under /opt/splunk and /etc)"
[[ -d "${SPLUNK_HOME}" ]] || die "${SPLUNK_HOME} does not exist - is Splunk installed?"
id "${SPLUNK_USER}" >/dev/null 2>&1 || die "user '${SPLUNK_USER}' does not exist"

# ---------------------------------------------------------------------------
# 1. Install certbot if absent. AL2023 ships certbot 2.6.0 directly in the
#    "amazonlinux" repository (verified `dnf list certbot`), so we use the
#    distro package rather than pip - no Python ABI churn, dnf manages
#    upgrades, and the systemd-side certbot-renew.timer we install in
#    step 6 below references /usr/bin/certbot which the rpm provides.
# ---------------------------------------------------------------------------
if ! command -v certbot >/dev/null 2>&1; then
  log "installing certbot via dnf (AL2023 carries certbot 2.6.0+ in amazonlinux repo)"
  dnf install -y --quiet certbot >/dev/null
fi
command -v certbot >/dev/null 2>&1 || die "certbot still not on PATH after install"

# ---------------------------------------------------------------------------
# 2. Stage the deploy hook BEFORE invoking certbot. Certbot 2.6 (the version
#    AL2023 ships) validates the --deploy-hook path exists in PATH at parse
#    time and refuses to run otherwise. The hook is a no-op on first issue
#    (RENEWED_DOMAINS is set by certbot only on actual renewals) but builds
#    the combined PEM and restarts splunkd on every subsequent renewal.
# ---------------------------------------------------------------------------
log "staging deploy hook at ${DEPLOY_HOOK}"
mkdir -p "$(dirname "${DEPLOY_HOOK}")"
cat > "${DEPLOY_HOOK}" <<'HOOK'
#!/usr/bin/env bash
# Installed by scripts/lib/install_letsencrypt_hec.sh. Runs as root via
# certbot's --deploy-hook after a successful renewal. RENEWED_DOMAINS is
# space-separated when multiple domains share a renewal; we walk all of
# them and refresh the combined PEM for each.
set -Eeuo pipefail
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
SPLUNK_USER="${SPLUNK_USER:-splunk}"
DEST="${SPLUNK_HOME}/etc/auth/hec-letsencrypt.pem"
for fqdn in ${RENEWED_DOMAINS:-}; do
  live="/etc/letsencrypt/live/${fqdn}"
  if [[ -f "${live}/cert.pem" ]]; then
    cat "${live}/cert.pem" "${live}/chain.pem" "${live}/privkey.pem" > "${DEST}"
    chown "${SPLUNK_USER}:${SPLUNK_USER}" "${DEST}"
    chmod 0600 "${DEST}"
  fi
done
# Prefer the systemd-managed unit if it exists (the cloud-init bootstrap
# enables Splunkd.service); otherwise fall back to the splunk CLI.
if systemctl list-unit-files Splunkd.service >/dev/null 2>&1; then
  systemctl restart Splunkd
else
  sudo -u "${SPLUNK_USER}" "${SPLUNK_HOME}/bin/splunk" restart || true
fi
HOOK
chmod 0750 "${DEPLOY_HOOK}"
chown root:root "${DEPLOY_HOOK}"

# ---------------------------------------------------------------------------
# 3. Issue or renew the cert. --standalone binds tcp/80 directly during the
#    ACME challenge; --pre-hook / --post-hook bracket a brief nginx stop
#    so we coexist with the SPA reverse proxy on the same port. --keep-
#    until-expiring makes re-runs cheap (no-op while >30 days remain).
# ---------------------------------------------------------------------------
EMAIL_ARGS=()
if [[ -n "${EMAIL}" ]]; then
  EMAIL_ARGS=(--email "${EMAIL}" --no-eff-email)
else
  EMAIL_ARGS=(--register-unsafely-without-email)
  warn "no EMAIL set; registering Let's Encrypt account without contact address (renewal warnings will not reach anyone)"
fi

# Hooks are no-ops when nginx is not installed (e.g. on a freshly-provisioned
# box where scripts/05b-frontend-public-proxy.sh has not run yet).
PRE_HOOK="systemctl is-active --quiet nginx && systemctl stop nginx || true"
POST_HOOK="systemctl is-enabled --quiet nginx 2>/dev/null && systemctl start nginx || true"

log "issuing/renewing cert for ${FQDN}"
certbot certonly \
  --standalone \
  --non-interactive \
  --agree-tos \
  --keep-until-expiring \
  --domain "${FQDN}" \
  --pre-hook "${PRE_HOOK}" \
  --post-hook "${POST_HOOK}" \
  --deploy-hook "${DEPLOY_HOOK}" \
  "${EMAIL_ARGS[@]}"

LIVE_DIR="/etc/letsencrypt/live/${FQDN}"
[[ -f "${LIVE_DIR}/cert.pem" && -f "${LIVE_DIR}/chain.pem" && -f "${LIVE_DIR}/privkey.pem" ]] \
  || die "expected live cert files under ${LIVE_DIR} after certbot run"

# ---------------------------------------------------------------------------
# 3. Build the combined PEM that Splunk HEC reads. Ownership splunk:splunk
#    and 0600 perms because the file contains the unencrypted private key.
# ---------------------------------------------------------------------------
log "writing combined PEM to ${DEST_PEM}"
mkdir -p "$(dirname "${DEST_PEM}")"
umask 077
cat "${LIVE_DIR}/cert.pem" "${LIVE_DIR}/chain.pem" "${LIVE_DIR}/privkey.pem" > "${DEST_PEM}"
chown "${SPLUNK_USER}:${SPLUNK_USER}" "${DEST_PEM}"
chmod 0600 "${DEST_PEM}"

# ---------------------------------------------------------------------------
# 4. Override Splunk's [http] stanza serverCert via system/local. We do
#    NOT edit splunk_httpinput/local/inputs.conf - that file is generated
#    by cloud-init and might be re-rendered. system/local always wins so
#    putting the override here is robust against the existing inputs.conf
#    being overwritten elsewhere.
# ---------------------------------------------------------------------------
log "writing HEC TLS override at ${OVERRIDE_INPUTS}"
mkdir -p "$(dirname "${OVERRIDE_INPUTS}")"
cat > "${OVERRIDE_INPUTS}" <<INPUTS
# Managed by scripts/lib/install_letsencrypt_hec.sh. Overrides the HEC
# [http] stanza's TLS material so the Splunk Enterprise box presents a
# browser-trusted certificate on tcp/8088 instead of the default
# self-signed cert. Required by ThousandEyes Cloud's Streaming integration.
[http]
enableSSL = 1
serverCert = ${DEST_PEM}
INPUTS
chown "${SPLUNK_USER}:${SPLUNK_USER}" "${OVERRIDE_INPUTS}"
chmod 0640 "${OVERRIDE_INPUTS}"

# ---------------------------------------------------------------------------
# 5. Issue an FQDN-correct cert for the splunkd management port (tcp/8089)
#    and wire [sslConfig]/serverCert to it. Required for Splunk Observability
#    Cloud's Log Observer Connect (LOC): the LOC connector dials
#    https://${FQDN}:8089/services/authorization/tokens from its cloud
#    egress to validate the integration. With the default Splunk cert the
#    test fails with "Invalid or incorrect certificate" (CN mismatch);
#    with a Let's Encrypt cert it fails because LE issues serverAuth-only
#    EKUs and Splunk's KVStore (mongod) needs clientAuth EKU on the same
#    cert (splunkd presents [sslConfig]/serverCert when acting as mongod
#    client too). Solution: mint a self-signed-by-SplunkCommonCA leaf cert
#    that has BOTH EKUs and the right SAN. This keeps mongod happy AND
#    lets the LOC integration save successfully when the SplunkCommonCA
#    is supplied as the integration's `certificate` field.
#
# The LE cert remains for HEC (8088) where the consumer (ThousandEyes)
# only needs serverAuth.
# ---------------------------------------------------------------------------
SPLUNKD_HOST_PEM="${SPLUNK_HOME}/etc/auth/splunkd-host.pem"
SPLUNK_CA_CERT="${SPLUNK_HOME}/etc/auth/cacert.pem"
SPLUNK_CA_BUNDLE="${SPLUNK_HOME}/etc/auth/ca.pem"
# Default Splunk CA key passphrase (hardcoded in fresh installs). Override
# only if you know it has been rotated; the default is what
# /opt/splunk/etc/auth/ca.pem was encrypted with at first-boot.
SPLUNK_CA_KEY_PASS="${SPLUNK_CA_KEY_PASS:-password}"

log "minting splunkd host cert for ${FQDN} (CN+SAN match, server+client EKU, signed by SplunkCommonCA)"
SPLUNKD_CERT_WORKDIR="$(mktemp -d)"
trap 'rm -rf "${SPLUNKD_CERT_WORKDIR}"' EXIT

cat > "${SPLUNKD_CERT_WORKDIR}/openssl.cnf" <<CNF
[req]
distinguished_name = req_dn
prompt = no
[req_dn]
CN = ${FQDN}
[v3_req]
subjectAltName = DNS:${FQDN}
extendedKeyUsage = serverAuth, clientAuth
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
CNF

openssl genrsa -out "${SPLUNKD_CERT_WORKDIR}/host.key" 2048 2>/dev/null
openssl req -new \
  -key "${SPLUNKD_CERT_WORKDIR}/host.key" \
  -out "${SPLUNKD_CERT_WORKDIR}/host.csr" \
  -config "${SPLUNKD_CERT_WORKDIR}/openssl.cnf" >/dev/null
openssl x509 -req \
  -in "${SPLUNKD_CERT_WORKDIR}/host.csr" \
  -CA "${SPLUNK_CA_BUNDLE}" -CAkey "${SPLUNK_CA_BUNDLE}" -CAcreateserial \
  -out "${SPLUNKD_CERT_WORKDIR}/host.crt" \
  -days 1095 -sha256 \
  -extensions v3_req -extfile "${SPLUNKD_CERT_WORKDIR}/openssl.cnf" \
  -passin "pass:${SPLUNK_CA_KEY_PASS}" >/dev/null 2>&1 \
  || die "failed to sign splunkd host cert with SplunkCommonCA (set SPLUNK_CA_KEY_PASS if non-default)"

cat \
  "${SPLUNKD_CERT_WORKDIR}/host.crt" \
  "${SPLUNKD_CERT_WORKDIR}/host.key" \
  "${SPLUNK_CA_CERT}" > "${SPLUNKD_HOST_PEM}"
chown "${SPLUNK_USER}:${SPLUNK_USER}" "${SPLUNKD_HOST_PEM}"
chmod 0600 "${SPLUNKD_HOST_PEM}"
openssl x509 -in "${SPLUNKD_HOST_PEM}" -noout -subject -ext subjectAltName,extendedKeyUsage \
  | sed 's/^/    /'

# Patch system/local/server.conf [sslConfig]: add serverCert override and
# blank out sslPassword (our key is unencrypted; leaving the encrypted
# default password causes splunkd to try to decrypt our plaintext key
# and fail). idempotent: re-runs replace any existing override.
SERVER_CONF="${SPLUNK_HOME}/etc/system/local/server.conf"
log "wiring splunkd [sslConfig]/serverCert -> ${SPLUNKD_HOST_PEM}"
python3 <<PY
import re, pathlib
p = pathlib.Path("${SERVER_CONF}")
text = p.read_text() if p.exists() else "[sslConfig]\n"
# strip any existing serverCert lines (anywhere)
text = re.sub(r"^serverCert\s*=.*\n", "", text, flags=re.MULTILINE)
DEST = "${SPLUNKD_HOST_PEM}"
new_text, n = re.subn(r"(\[sslConfig\]\n)", "\\\\1serverCert = " + DEST + "\n", text, count=1)
if n == 0:
    new_text = text.rstrip() + "\n\n[sslConfig]\nserverCert = " + DEST + "\n"
new_text = re.sub(r"sslPassword\s*=.*", "sslPassword = ", new_text)
p.write_text(new_text)
PY
chown "${SPLUNK_USER}:${SPLUNK_USER}" "${SERVER_CONF}"

# ---------------------------------------------------------------------------
# 5b. Enable token authentication so a custom role can hold edit_tokens_own
#     (Splunk refuses to assign token capabilities until [tokenAuth] is on).
#     LOC mints a JWT the first time it federates a search; without this
#     the integration save passes but actual log queries return empty.
# ---------------------------------------------------------------------------
AUTH_CONF="${SPLUNK_HOME}/etc/system/local/authentication.conf"
log "enabling [tokenAuth] in ${AUTH_CONF}"
python3 <<PY
import re, pathlib
p = pathlib.Path("${AUTH_CONF}")
text = p.read_text() if p.exists() else ""
if re.search(r"^\[tokenAuth\]", text, flags=re.MULTILINE):
    text = re.sub(r"(\[tokenAuth\][\s\S]*?)disabled\s*=.*", r"\1disabled = false", text)
else:
    text = (text.rstrip() + "\n\n[tokenAuth]\ndisabled = false\n").lstrip()
p.write_text(text)
PY
chown "${SPLUNK_USER}:${SPLUNK_USER}" "${AUTH_CONF}"
chmod 0644 "${AUTH_CONF}"

# ---------------------------------------------------------------------------
# 5c. Halve volume of natwest application logs.
#     Append (idempotent) a `[kube:container:service]` props stanza and a
#     `[halve_natwest_logs]` transforms entry that drops ~50% of incoming
#     events at parse time. Halving uses a deterministic regex on the
#     hh:mm:ss seconds field's last digit (drops if odd) -- works for
#     both ISO timestamps in JSON-formatted app logs AND Apache-style
#     access log timestamps.
#
#     Why here: the OTel Collector v0.150 `probabilistic_sampler` fails
#     closed for log records that lack W3C TraceID context (filelog
#     records have none) and OTTL has no modulo / Hash builtin to
#     construct a 50/50 split in the agent's `filter` processor. Splunk
#     `transforms.conf REGEX -> nullQueue` is the canonical, predictable
#     mechanism for this volume control. See also collector/values.yaml
#     for the full rationale and trace -> log fidelity trade-off note.
# ---------------------------------------------------------------------------
PROPS_CONF="${SPLUNK_HOME}/etc/system/local/props.conf"
TRANSFORMS_CONF="${SPLUNK_HOME}/etc/system/local/transforms.conf"
log "wiring [kube:container:service] -> halve_natwest_logs in ${PROPS_CONF##*/local/}"
python3 <<PY
import pathlib, re
PROPS = pathlib.Path("${PROPS_CONF}")
TFM   = pathlib.Path("${TRANSFORMS_CONF}")
props_block = (
    "\n# Halve natwest-payments app log volume at index time. See\n"
    "# scripts/lib/install_letsencrypt_hec.sh section 5c for rationale.\n"
    "[kube:container:service]\n"
    "TRANSFORMS-halve = halve_natwest_logs\n"
)
tfm_block = (
    "\n# Drop events whose hh:mm:ss seconds last digit is odd. Matches both\n"
    "# ISO timestamps (T08:15:55... in JSON-formatted app logs) and Apache-\n"
    "# style access log timestamps ([02/May/2026:08:15:55 +0000]).\n"
    "[halve_natwest_logs]\n"
    "REGEX = (?:T|:)\\\\d{2}:\\\\d{2}:\\\\d[13579]\n"
    "DEST_KEY = queue\n"
    "FORMAT = nullQueue\n"
)
# props
text = PROPS.read_text() if PROPS.exists() else ""
if not re.search(r"^\\[kube:container:service\\]", text, flags=re.MULTILINE):
    PROPS.write_text(text.rstrip() + "\n" + props_block)
# transforms
text = TFM.read_text() if TFM.exists() else ""
if not re.search(r"^\\[halve_natwest_logs\\]", text, flags=re.MULTILINE):
    TFM.write_text(text.rstrip() + "\n" + tfm_block)
PY
chown "${SPLUNK_USER}:${SPLUNK_USER}" "${PROPS_CONF}" "${TRANSFORMS_CONF}"
chmod 0644 "${PROPS_CONF}" "${TRANSFORMS_CONF}"

# ---------------------------------------------------------------------------
# 6. Daily renewal timer. We install our own (rather than relying on the
#    rpm's certbot-renew.timer if any) so we control the schedule and the
#    log target. The deploy hook above takes care of the Splunk-specific
#    work; the timer just attempts renewal.
# ---------------------------------------------------------------------------
CERTBOT_BIN="$(command -v certbot)"
log "installing certbot-renew systemd timer (using ${CERTBOT_BIN})"
cat > /etc/systemd/system/certbot-renew.service <<SVC
[Unit]
Description=Let's Encrypt renewal for Splunk HEC
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${CERTBOT_BIN} renew --quiet --no-random-sleep-on-renew
SVC

cat > /etc/systemd/system/certbot-renew.timer <<'TMR'
[Unit]
Description=Daily Let's Encrypt renewal attempt

[Timer]
OnCalendar=daily
RandomizedDelaySec=12h
Persistent=true

[Install]
WantedBy=timers.target
TMR

systemctl daemon-reload
systemctl enable --now certbot-renew.timer >/dev/null

# ---------------------------------------------------------------------------
# 7. Activate the new cert. tcp/8088 only re-reads SSL on a process
#    restart; "splunk reload" or _reload REST endpoints are insufficient
#    for [http] listener changes.
# ---------------------------------------------------------------------------
log "restarting splunkd to load the new HEC cert"
if systemctl list-unit-files Splunkd.service >/dev/null 2>&1; then
  systemctl restart Splunkd
else
  sudo -u "${SPLUNK_USER}" "${SPLUNK_HOME}/bin/splunk" restart
fi

log "done."
log "  cert:  ${LIVE_DIR}/cert.pem"
openssl x509 -in "${LIVE_DIR}/cert.pem" -noout -subject -issuer -dates 2>/dev/null \
  | sed 's/^/    /'

cat <<'NEXT'

Next:
  1. Probe HEC TLS from anywhere on the public internet:
       openssl s_client -connect <FQDN>:8088 -servername <FQDN> </dev/null \
         | openssl x509 -noout -subject -issuer
     The cert should now be issued by "Let's Encrypt" / "R10" or similar.
  2. Drive the ThousandEyes Cloud streaming integration:
       bash scripts/09b-create-te-streams.sh
     That script POSTs four /v7/stream entries (one per HEC token from
     secrets/te-state.json) and binds them to TE-01 .. TE-06. After ~1
     minute the ITSI Digital Customer Experience tier KPIs flip from
     Unknown / N/A to real values.
NEXT
