#!/usr/bin/env bash
# Apply the expanded Splunk Enterprise log catalogue to an already-running
# instance. cloud-init in terraform/cloud-init/splunk-enterprise.tftpl is
# strictly run-once (gated by /var/lib/splunk-bootstrap.done); this script
# is the in-place equivalent for an existing demo box.
#
# What it does (idempotent end-to-end):
#   1. Ships indexes.conf + props.conf + metadata into
#      /opt/splunk/etc/apps/natwest_demo_inputs/local/.
#   2. Adds the two new HEC tokens (firehose + scripts) to
#      /opt/splunk/etc/apps/splunk_httpinput/local/inputs.conf alongside
#      the existing otel-collector token, widening the otel-collector
#      token's index allow-list to include nwpay_* indexes.
#   3. Validates the rendered config via `splunk btool check`.
#   4. Restarts splunkd via systemd and waits for it to come back up.
#
# Required env (sourced from .env via lib.sh if available):
#   TF_VAR_splunk_enterprise_admin_password - Splunk admin password.
#
# Optional env (with sane defaults from terraform output):
#   SPLUNK_ENTERPRISE_HOST    default itsi.splunk-observability.com
#   SSH_USER                  default ec2-user
#   SSH_KEY                   default <repo>/terraform/splunk-enterprise.pem
#   SKIP_RESTART=1            skip the splunkd restart (config will only
#                             pick up on next restart - useful when batching
#                             with 06-install-itsi.sh or similar).

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_cmd ssh scp terraform

SPLUNK_ENTERPRISE_HOST="${SPLUNK_ENTERPRISE_HOST:-itsi.splunk-observability.com}"
SSH_USER="${SSH_USER:-ec2-user}"
SSH_KEY="${SSH_KEY:-${REPO_ROOT}/terraform/splunk-enterprise.pem}"
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:-admin}"
: "${TF_VAR_splunk_enterprise_admin_password:?Set TF_VAR_splunk_enterprise_admin_password (in .env or environment)}"
SPLUNK_ADMIN_PASS="${TF_VAR_splunk_enterprise_admin_password}"

SSH_KEY="$(ensure_splunk_ssh_key "${SSH_KEY}")"
chmod 600 "${SSH_KEY}" 2>/dev/null || true

# Pull the three HEC tokens from terraform outputs so this script never
# embeds them. tf_output returns the literal string 'null' when the output
# is unset, so guard against that.
fetch_token() {
  local name="$1"
  local val
  val="$(terraform -chdir="${TERRAFORM_DIR}" output -raw "$name" 2>/dev/null || true)"
  [[ -n "${val}" && "${val}" != "null" ]] || fail "terraform output '${name}' is empty/null. Run 'terraform apply' first."
  printf '%s' "${val}"
}

OTEL_TOKEN="$(fetch_token splunk_enterprise_hec_token)"
FIREHOSE_TOKEN="$(fetch_token splunk_enterprise_hec_token_firehose)"
SCRIPTS_TOKEN="$(fetch_token splunk_enterprise_hec_token_scripts)"

SSH_OPTS=(
  -i "${SSH_KEY}"
  -o "StrictHostKeyChecking=accept-new"
  -o "UserKnownHostsFile=${HOME}/.ssh/known_hosts"
  -o "ConnectTimeout=10"
  -o "ServerAliveInterval=30"
  -o "BatchMode=yes"
)

ssh_run() {
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SPLUNK_ENTERPRISE_HOST}" "$@" </dev/null
}

scp_to_remote() {
  scp "${SSH_OPTS[@]}" "$1" "${SSH_USER}@${SPLUNK_ENTERPRISE_HOST}:$2"
}

# ----------------------------------------------------------------------------
# 0. Ensure Java 17 is installed before anything else, so the ITSI rules
#    engine (NEAP grouper) can start when splunkd comes back up. Without
#    Java, notable events accumulate in itsi_tracked_alerts but the
#    Episode Review / Event Analytics screen stays empty (zero episodes
#    land in itsi_grouped_alerts or the itsi_notable_event_group KV
#    collection). The failure mode is silent unless you tail
#    /opt/splunk/var/log/splunk/itsi_queue_re_init.log.
#
#    On AL2023 the corretto packages are in the default 'amazonlinux'
#    repo, so 'dnf install' completes in ~10s. The block also persists
#    JAVA_HOME into /opt/splunk/etc/splunk-launch.conf so splunkd
#    inherits it on every restart (the systemd unit otherwise scrubs
#    the environment).
# ----------------------------------------------------------------------------
log "[00b] ensuring Java 17 is installed on Splunk box for ITSI rules engine"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SPLUNK_ENTERPRISE_HOST}" 'bash -s' <<'JAVA_PROVISION'
set -Eeuo pipefail
if ! command -v java >/dev/null 2>&1; then
  echo "[00b/java] java not on PATH - installing java-17-amazon-corretto-headless"
  sudo dnf install -y --quiet java-17-amazon-corretto-headless \
    || sudo yum install -y java-17-amazon-corretto-headless
fi
JAVA_HOME="/usr/lib/jvm/java-17-amazon-corretto.x86_64"
if [ ! -x "${JAVA_HOME}/bin/java" ]; then
  echo "[00b/java] expected ${JAVA_HOME}/bin/java to exist post-install" >&2
  exit 1
fi
# Persist JAVA_HOME for splunkd (systemd unit sources this).
LAUNCH_CONF=/opt/splunk/etc/splunk-launch.conf
if ! sudo grep -q '^JAVA_HOME=' "${LAUNCH_CONF}" 2>/dev/null; then
  echo "[00b/java] adding JAVA_HOME=${JAVA_HOME} to ${LAUNCH_CONF}"
  echo "JAVA_HOME=${JAVA_HOME}" | sudo tee -a "${LAUNCH_CONF}" >/dev/null
fi
# Make JAVA_HOME available to interactive presenter shells too.
if [ ! -f /etc/profile.d/java17.sh ]; then
  printf 'export JAVA_HOME=%s\nexport PATH=$JAVA_HOME/bin:$PATH\n' "${JAVA_HOME}" \
    | sudo tee /etc/profile.d/java17.sh >/dev/null
  sudo chmod 0644 /etc/profile.d/java17.sh
fi
java -version 2>&1 | head -1
JAVA_PROVISION

# ----------------------------------------------------------------------------
# 1. Render the configs locally into a staging directory, scp once, then
#    `sudo install` them into place. The local render keeps secrets out of
#    a heredoc-on-the-wire (ssh tty) and lets us re-run without partial
#    writes if the network drops mid-transfer.
# ----------------------------------------------------------------------------
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGE_DIR}"' EXIT

cat > "${STAGE_DIR}/indexes.conf" <<'INDEXCONF'
[nwpay_audit]
homePath   = $SPLUNK_DB/nwpay_audit/db
coldPath   = $SPLUNK_DB/nwpay_audit/colddb
thawedPath = $SPLUNK_DB/nwpay_audit/thaweddb
maxTotalDataSizeMB = 5120
frozenTimePeriodInSecs = 604800

[nwpay_infra]
homePath   = $SPLUNK_DB/nwpay_infra/db
coldPath   = $SPLUNK_DB/nwpay_infra/colddb
thawedPath = $SPLUNK_DB/nwpay_infra/thaweddb
maxTotalDataSizeMB = 5120
frozenTimePeriodInSecs = 604800

[aws_cloudtrail]
homePath   = $SPLUNK_DB/aws_cloudtrail/db
coldPath   = $SPLUNK_DB/aws_cloudtrail/colddb
thawedPath = $SPLUNK_DB/aws_cloudtrail/thaweddb
maxTotalDataSizeMB = 5120
frozenTimePeriodInSecs = 1209600

[aws_vpcflow]
homePath   = $SPLUNK_DB/aws_vpcflow/db
coldPath   = $SPLUNK_DB/aws_vpcflow/colddb
thawedPath = $SPLUNK_DB/aws_vpcflow/thaweddb
maxTotalDataSizeMB = 10240
frozenTimePeriodInSecs = 604800

[aws_guardduty]
homePath   = $SPLUNK_DB/aws_guardduty/db
coldPath   = $SPLUNK_DB/aws_guardduty/colddb
thawedPath = $SPLUNK_DB/aws_guardduty/thaweddb
maxTotalDataSizeMB = 2048
frozenTimePeriodInSecs = 2592000

[aws_eks_audit]
homePath   = $SPLUNK_DB/aws_eks_audit/db
coldPath   = $SPLUNK_DB/aws_eks_audit/colddb
thawedPath = $SPLUNK_DB/aws_eks_audit/thaweddb
maxTotalDataSizeMB = 5120
frozenTimePeriodInSecs = 1209600
INDEXCONF

cat > "${STAGE_DIR}/props.conf" <<'PROPSCONF'
[nwpay:payment_audit]
INDEXED_EXTRACTIONS = json
KV_MODE = none
TRUNCATE = 0
SHOULD_LINEMERGE = false
LINE_BREAKER = ([\r\n]+)
TIME_PREFIX = "@timestamp"\s*:\s*"
TIME_FORMAT = %Y-%m-%dT%H:%M:%S.%3N%Z
MAX_TIMESTAMP_LOOKAHEAD = 32

[nwpay:auth]
INDEXED_EXTRACTIONS = json
KV_MODE = none
TRUNCATE = 0
SHOULD_LINEMERGE = false
LINE_BREAKER = ([\r\n]+)
TIME_PREFIX = "@timestamp"\s*:\s*"
TIME_FORMAT = %Y-%m-%dT%H:%M:%S.%3N%Z

[nwpay:chaos]
INDEXED_EXTRACTIONS = json
KV_MODE = none
TRUNCATE = 0
SHOULD_LINEMERGE = false
LINE_BREAKER = ([\r\n]+)
TIME_PREFIX = "@timestamp"\s*:\s*"
TIME_FORMAT = %Y-%m-%dT%H:%M:%S.%3N%Z

[nginx:access]
INDEXED_EXTRACTIONS = json
KV_MODE = none
TRUNCATE = 0
SHOULD_LINEMERGE = false
LINE_BREAKER = ([\r\n]+)

[nginx:error]
SHOULD_LINEMERGE = true
MUST_BREAK_AFTER = ^\d{4}/\d{2}/\d{2}\s\d{2}:\d{2}:\d{2}

[postgresql]
SHOULD_LINEMERGE = true
MUST_BREAK_AFTER = ^\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}

[postgres:dbm]
INDEXED_EXTRACTIONS = json
KV_MODE = none
TRUNCATE = 0
SHOULD_LINEMERGE = false
LINE_BREAKER = ([\r\n]+)

[redis]
SHOULD_LINEMERGE = false
LINE_BREAKER = ([\r\n]+)

[kafka]
SHOULD_LINEMERGE = true
MUST_BREAK_AFTER = ^\[\d{4}-\d{2}-\d{2}

[kafka:server]
SHOULD_LINEMERGE = true
MUST_BREAK_AFTER = ^\[\d{4}-\d{2}-\d{2}
PROPSCONF

cat > "${STAGE_DIR}/savedsearches.conf" <<'SAVEDCONF'
[Infra Logs - Postgres slow statements]
description = Slow Postgres statements from container stderr (nwpay_infra)
search = index=nwpay_infra sourcetype=postgresql "duration:" earliest=-24h | head 100
dispatch.earliest_time = -24h@h
dispatch.latest_time = now
is_scheduled = 0

[Infra Logs - Kafka ERROR WARN]
description = Kafka broker WARN/ERROR lines from nwpay_infra
search = index=nwpay_infra sourcetype=kafka (ERROR OR WARN) earliest=-24h | head 100
dispatch.earliest_time = -24h@h
dispatch.latest_time = now
is_scheduled = 0

[Infra Logs - Redis evictions OOM]
description = Redis eviction / OOM signals from nwpay_infra
search = index=nwpay_infra sourcetype=redis (evict* OR OOM OR "out of memory") earliest=-24h | head 100
dispatch.earliest_time = -24h@h
dispatch.latest_time = now
is_scheduled = 0
SAVEDCONF

cat > "${STAGE_DIR}/local.meta" <<'METACONF'
[]
access = read : [ * ], write : [ admin, power ]
export = system
METACONF

# inputs.conf inside natwest_demo_inputs: monitor stanzas for log files
# on the same host (public-proxy nginx). Distinct from the HEC-token
# inputs.conf below which lives in splunk_httpinput.
cat > "${STAGE_DIR}/monitors.conf" <<'MONITORCONF'
[monitor:///var/log/nginx/spa-access.log]
disabled = 0
sourcetype = nginx:access
index = nwpay_infra
source = nginx-public-proxy

[monitor:///var/log/nginx/spa-error.log]
disabled = 0
sourcetype = nginx:error
index = nwpay_infra
source = nginx-public-proxy
MONITORCONF

# inputs.conf merges the existing otel-collector stanza (widened allow-list)
# with the new firehose + scripts tokens. The tokens are interpolated into
# the staged file from terraform outputs - never echoed to stdout, never
# committed.
umask 077
cat > "${STAGE_DIR}/inputs.conf" <<INPUTSCONF
[http]
disabled = 0
enableSSL = 1
port = 8088

[http://otel-collector]
disabled = 0
token = ${OTEL_TOKEN}
indexes = main, _internal, itsi_im_metrics, nwpay_audit, nwpay_infra
index = main

[http://aws-firehose]
disabled = 0
token = ${FIREHOSE_TOKEN}
indexes = aws_cloudtrail, aws_vpcflow, aws_guardduty, aws_eks_audit
index = aws_cloudtrail

[http://demo-scripts]
disabled = 0
token = ${SCRIPTS_TOKEN}
indexes = nwpay_audit
index = nwpay_audit
INPUTSCONF
umask 022

# ----------------------------------------------------------------------------
# 2. Push to a /tmp staging dir, then sudo-install with strict perms.
# ----------------------------------------------------------------------------
log "remote preflight: ssh ${SSH_USER}@${SPLUNK_ENTERPRISE_HOST}"
ssh_run "true" || fail "cannot SSH to ${SSH_USER}@${SPLUNK_ENTERPRISE_HOST} with key ${SSH_KEY}"

REMOTE_STAGE="/tmp/natwest-splunk-config-$$"
ssh_run "mkdir -p '${REMOTE_STAGE}' && chmod 700 '${REMOTE_STAGE}'"

log "uploading rendered configs to ${SSH_USER}@${SPLUNK_ENTERPRISE_HOST}:${REMOTE_STAGE}"
scp_to_remote "${STAGE_DIR}/indexes.conf"  "${REMOTE_STAGE}/indexes.conf"
scp_to_remote "${STAGE_DIR}/props.conf"    "${REMOTE_STAGE}/props.conf"
scp_to_remote "${STAGE_DIR}/local.meta"    "${REMOTE_STAGE}/local.meta"
scp_to_remote "${STAGE_DIR}/monitors.conf" "${REMOTE_STAGE}/monitors.conf"
scp_to_remote "${STAGE_DIR}/savedsearches.conf" "${REMOTE_STAGE}/savedsearches.conf"
scp_to_remote "${STAGE_DIR}/inputs.conf"   "${REMOTE_STAGE}/inputs.conf"

log "installing into /opt/splunk/etc/apps/{natwest_demo_inputs,splunk_httpinput}"
ssh_run "sudo bash -s" <<REMOTE_INSTALL
set -Eeuo pipefail
APP_DIR=/opt/splunk/etc/apps/natwest_demo_inputs
INPUT_DIR=/opt/splunk/etc/apps/splunk_httpinput
install -d -o splunk -g splunk -m 0750 "\$APP_DIR/local" "\$APP_DIR/metadata"
install -o splunk -g splunk -m 0640 "${REMOTE_STAGE}/indexes.conf"  "\$APP_DIR/local/indexes.conf"
install -o splunk -g splunk -m 0640 "${REMOTE_STAGE}/props.conf"    "\$APP_DIR/local/props.conf"
install -o splunk -g splunk -m 0640 "${REMOTE_STAGE}/local.meta"    "\$APP_DIR/metadata/local.meta"
install -o splunk -g splunk -m 0640 "${REMOTE_STAGE}/monitors.conf" "\$APP_DIR/local/inputs.conf"
install -o splunk -g splunk -m 0640 "${REMOTE_STAGE}/savedsearches.conf" "\$APP_DIR/local/savedsearches.conf"

# splunk_httpinput/local/inputs.conf may already contain stanzas written
# by other operators / scripts (e.g. ThousandEyes HEC tokens added by
# scripts/09b-create-te-streams.sh). Overwriting wholesale would silently
# drop them and the operator would only find out when ThousandEyes data
# stopped flowing. Instead, strip out the four stanzas this script owns
# ([http], [http://otel-collector], [http://aws-firehose],
# [http://demo-scripts]) from the existing file, then append our freshly
# rendered block. Install atomically with -T so splunkd can't read a
# half-written file mid-merge.
install -d -o splunk -g splunk -m 0750 "\$INPUT_DIR/local"
OUR_STANZAS='^\[(http|http://otel-collector|http://aws-firehose|http://demo-scripts)\]\$'
MERGED_TMP="\$(mktemp -p "${REMOTE_STAGE}" merged.XXXXXX)"
chmod 0600 "\$MERGED_TMP"
if [[ -f "\$INPUT_DIR/local/inputs.conf" ]]; then
  awk -v drop_re="\$OUR_STANZAS" '
    /^\[/  { drop = (\$0 ~ drop_re) }
    !drop  { print }
  ' "\$INPUT_DIR/local/inputs.conf" > "\$MERGED_TMP"
  # Trailing newline so the appended block starts on its own line even if
  # the original file ended without one.
  printf '\n' >> "\$MERGED_TMP"
fi
cat "${REMOTE_STAGE}/inputs.conf" >> "\$MERGED_TMP"
install -o splunk -g splunk -m 0640 -T "\$MERGED_TMP" "\$INPUT_DIR/local/inputs.conf"

# Wipe the staging directory so the rendered tokens don't linger on disk.
rm -rf "${REMOTE_STAGE}"
REMOTE_INSTALL

# ----------------------------------------------------------------------------
# 3. Validate via btool. btool reads the merged on-disk config without
#    needing a splunkd restart, so if it can't see our stanzas it means
#    the install/merge step above silently failed (e.g. SCP partial write,
#    perms issue, awk merge dropped the wrong stanza). Treat that as fatal
#    rather than warn - this script used to ship the warn and the operator
#    only discovered "Invalid token" responses to HEC POSTs hours later.
# ----------------------------------------------------------------------------
log "validating rendered config via splunk btool"
ssh_run "sudo -u splunk /opt/splunk/bin/splunk btool indexes list --debug 2>/dev/null | grep -E 'nwpay_|aws_' >/dev/null" \
  || fail "btool cannot see nwpay_/aws_ indexes in /opt/splunk/etc/apps/natwest_demo_inputs/local/indexes.conf - install step on the remote silently failed; ssh in and re-run by hand"
ssh_run "sudo -u splunk /opt/splunk/bin/splunk btool inputs list --debug 2>/dev/null | grep -E 'http://(aws-firehose|demo-scripts)' >/dev/null" \
  || fail "btool cannot see [http://aws-firehose] / [http://demo-scripts] in /opt/splunk/etc/apps/splunk_httpinput/local/inputs.conf - the merge step on the remote silently failed; inspect the file by hand"

# ----------------------------------------------------------------------------
# 4. Restart splunkd unless the operator opted out.
# ----------------------------------------------------------------------------
if [[ "${SKIP_RESTART:-0}" == "1" ]]; then
  log "SKIP_RESTART=1: leaving splunkd untouched - new indexes/tokens activate on next restart"
  exit 0
fi

log "restarting splunkd via systemd"
ssh_run "sudo systemctl restart Splunkd"

log "waiting for splunkd to be ready (max 300s)"
waited=0
while (( waited < 300 )); do
  if ssh_run "sudo -u splunk /opt/splunk/bin/splunk status 2>/dev/null | grep -q 'splunkd is running'"; then
    log "  splunkd is running"
    break
  fi
  sleep 5
  waited=$(( waited + 5 ))
done
[[ ${waited} -lt 300 ]] || fail "splunkd did not come up within 300s"

log "verifying new indexes are addressable"
for idx in nwpay_audit nwpay_infra aws_cloudtrail aws_vpcflow aws_guardduty aws_eks_audit; do
  if ssh_run "curl -ksu '${SPLUNK_ADMIN_USER}:${SPLUNK_ADMIN_PASS}' \
                'https://localhost:8089/services/data/indexes/${idx}?output_mode=json' \
                | grep -q '\"name\":\"${idx}\"'"; then
    log "  [ok] ${idx}"
  else
    warn "  [missing] ${idx} (check /opt/splunk/var/log/splunk/splunkd.log)"
  fi
done

log "config update complete"
log "  HEC base URL:   $(terraform -chdir=\"${TERRAFORM_DIR}\" output -raw splunk_enterprise_hec_endpoint_public 2>/dev/null || echo '<terraform output unavailable>')"
log "  Token (otel):     ********"
log "  Token (firehose): ********"
log "  Token (scripts):  ********"

unset OTEL_TOKEN FIREHOSE_TOKEN SCRIPTS_TOKEN SPLUNK_ADMIN_PASS
