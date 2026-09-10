#!/usr/bin/env bash
# OS + Splunk capacity snapshot, then optional apply of Splunk platform tuning
# that helps ITSI (more concurrent searches + HEC ingest pipelines) when the
# host is not CPU- or memory-saturated. Does not change ITSI feature flags
# (e.g. staggered KPI scheduling stays default).
#
# Usage:
#   ./scripts/00c-tune-splunk-performance.sh                # diagnosis only
#   ./scripts/00c-tune-splunk-performance.sh --apply        # auto if headroom
#   ./scripts/00c-tune-splunk-performance.sh --apply --force  # always apply
#
# Required (for --apply):
#   TF_VAR_splunk_enterprise_admin_password
# Optional env:
#   SPLUNK_ENTERPRISE_HOST, SSH_USER, SSH_KEY (same defaults as 00b-update-splunk-config.sh)
#   TUNE_MAX_SEARCHES_PER_CPU   (default 2)
#   TUNE_BASE_MAX_SEARCHES     (default 12)
#   TUNE_MAX_PIPELINES         (default: min(8, remote nproc), or set explicitly)
#   TUNE_SCHED_MAX_SEARCHES_PERC (default 70)
#   SKIP_RESTART=1             skip splunk restart after config write
#
# Config is written to:
#   /opt/splunk/etc/apps/natwest_demo_inputs/local/limits.conf
#   /opt/splunk/etc/apps/natwest_demo_inputs/local/server.conf
# so system/local (e.g. Let's Encrypt) is left untouched.
#
# Reference: Splunk limits.conf [search] / [scheduler]; server.conf [general]
# parallelIngestionPipelines. ITSI KPI load is mostly scheduled searches.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_cmd ssh scp

SPLUNK_HOME="/opt/splunk"
SPLUNK_ENTERPRISE_HOST="${SPLUNK_ENTERPRISE_HOST:-itsi.splunk-observability.com}"
SSH_USER="${SSH_USER:-ec2-user}"
SSH_KEY="${SSH_KEY:-${REPO_ROOT}/terraform/splunk-enterprise.pem}"

TUNE_MAX_SEARCHES_PER_CPU="${TUNE_MAX_SEARCHES_PER_CPU:-2}"
TUNE_BASE_MAX_SEARCHES="${TUNE_BASE_MAX_SEARCHES:-12}"
TUNE_SCHED_MAX_SEARCHES_PERC="${TUNE_SCHED_MAX_SEARCHES_PERC:-70}"

APPLY=0
FORCE=0
for arg in "$@"; do
  case "${arg}" in
    --apply) APPLY=1 ;;
    --force) FORCE=1 ;;
    -h|--help)
      sed -n '1,25p' "$0"
      exit 0
      ;;
    *) fail "unknown flag: ${arg}" ;;
  esac
done

SSH_KEY="$(ensure_splunk_ssh_key "${SSH_KEY}")"
chmod 600 "${SSH_KEY}" 2>/dev/null || true

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

# ---------------------------------------------------------------------------
# 1) O/S and Splunk process snapshot (read-only)
# ---------------------------------------------------------------------------
log "host: ${SSH_USER}@${SPLUNK_ENTERPRISE_HOST} (ssh preflight)"
ssh_run "true" || fail "cannot SSH to ${SPLUNK_ENTERPRISE_HOST}"

log "── O/S (Amazon Linux 2023 + demo footprint from terraform) ──"
ssh_run "echo '  kernel:' \$(uname -r); \
  echo '  uptime:'; uptime; \
  echo '  cpu count:' \$(nproc); \
  echo '  loadavg:' \$(cat /proc/loadavg | awk '{print \$1,\$2,\$3}'); \
  echo '  memory:'; free -h 2>/dev/null | sed -n '1,2p'; \
  echo '  root disk:'; df -h / 2>/dev/null | tail -1; \
  echo '  top memory (name,rss):'; ps -eo comm,rss --sort=-rss 2>/dev/null | head -6"

REMOTE_NPROC="$(ssh_run "nproc")"
log "  remote nproc: ${REMOTE_NPROC}"

log "── Splunk ──"
ssh_run "sudo -u splunk '${SPLUNK_HOME}/bin/splunk' status 2>/dev/null | head -5 || true"
ssh_run "sudo -u splunk '${SPLUNK_HOME}/bin/splunk' show kvstore-status 2>/dev/null | head -8 || true"

# ---------------------------------------------------------------------------
# 2) Headroom heuristic (skip unless --force)
# ---------------------------------------------------------------------------
LOAD1="$(ssh_run "awk '{print \$1}' /proc/loadavg")"
MEM_AVAIL_KB="$(ssh_run "grep MemAvailable /proc/meminfo | awk '{print \$2}'")"
CPUS="${REMOTE_NPROC}"

# Bash float compare via awk
OVERLOAD="$(awk -v l="${LOAD1}" -v c="${CPUS}" 'BEGIN { print (l > c * 1.25) ? 1 : 0 }')"
LOW_MEM="$(awk -v k="${MEM_AVAIL_KB}" 'BEGIN { print (k < 1500000) ? 1 : 0 }')"

log "── Headroom check ──"
log "  loadavg1=${LOAD1}  cpus=${CPUS}  (overload if load > 1.25×cpus)"
log "  MemAvailable_kb=${MEM_AVAIL_KB}  (low if < ~1.5GB)"

HEADROOM_OK=1
if [[ "${OVERLOAD}" == "1" ]]; then
  warn "CPU saturation suspected — skipping automated tuning unless --force"
  HEADROOM_OK=0
fi
if [[ "${LOW_MEM}" == "1" ]]; then
  warn "Low MemAvailable — skipping automated tuning unless --force"
  HEADROOM_OK=0
fi

if (( APPLY )) && (( ! FORCE )) && (( ! HEADROOM_OK )); then
  warn "Not applying (no headroom). Re-run with --apply --force to override."
  exit 0
fi

if (( ! APPLY )); then
  log "Diagnosis only. To apply tuning: $0 --apply"
  exit 0
fi

# ---------------------------------------------------------------------------
# 3) Render config locally (no secrets in files)
# ---------------------------------------------------------------------------
TUNE_MAX_PIPELINES="${TUNE_MAX_PIPELINES:-}"
if [[ -z "${TUNE_MAX_PIPELINES}" ]]; then
  if (( REMOTE_NPROC > 8 )); then
    TUNE_MAX_PIPELINES=8
  elif (( REMOTE_NPROC < 2 )); then
    TUNE_MAX_PIPELINES=2
  else
    TUNE_MAX_PIPELINES="${REMOTE_NPROC}"
  fi
fi

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGE_DIR}"' EXIT

cat > "${STAGE_DIR}/limits.conf" <<EOF
# ${SPLUNK_HOME}/etc/apps/natwest_demo_inputs/local/limits.conf
# Card-payment demo: raise search scheduler capacity for ITSI KPI / saved searches
# when the EC2 instance has CPU headroom. Merged with system defaults.
[search]
max_searches_per_cpu = ${TUNE_MAX_SEARCHES_PER_CPU}
base_max_searches = ${TUNE_BASE_MAX_SEARCHES}

[scheduler]
max_searches_perc = ${TUNE_SCHED_MAX_SEARCHES_PERC}
EOF

cat > "${STAGE_DIR}/server.conf" <<EOF
# ${SPLUNK_HOME}/etc/apps/natwest_demo_inputs/local/server.conf
# HEC / parsing throughput on single-instance Splunk
[general]
parallelIngestionPipelines = ${TUNE_MAX_PIPELINES}
EOF

log "── Applying (pipelines=${TUNE_MAX_PIPELINES}, max_searches_per_cpu=${TUNE_MAX_SEARCHES_PER_CPU}, base_max_searches=${TUNE_BASE_MAX_SEARCHES}) ──"

scp "${SSH_OPTS[@]}" "${STAGE_DIR}/limits.conf" "${STAGE_DIR}/server.conf" \
  "${SSH_USER}@${SPLUNK_ENTERPRISE_HOST}:/tmp/"

ssh_run "sudo bash -s" <<REMOTE
set -Eeuo pipefail
APP_DIR=${SPLUNK_HOME}/etc/apps/natwest_demo_inputs
install -d -o splunk -g splunk -m 0750 "\$APP_DIR/local"
install -o splunk -g splunk -m 0640 /tmp/limits.conf "\$APP_DIR/local/limits.conf"
install -o splunk -g splunk -m 0640 /tmp/server.conf "\$APP_DIR/local/server.conf"
rm -f /tmp/limits.conf /tmp/server.conf
sudo -u splunk ${SPLUNK_HOME}/bin/splunk btool limits list search 2>/dev/null \
  | grep -E '^(base_max_searches|max_searches_per_cpu)' || true
REMOTE

if [[ "${SKIP_RESTART:-0}" == "1" ]]; then
  log "SKIP_RESTART=1: restart splunkd manually to activate"
  exit 0
fi

log "restarting splunkd via systemd"
ssh_run "sudo systemctl restart Splunkd"

waited=0
while (( waited < 300 )); do
  if ssh_run "sudo -u splunk '${SPLUNK_HOME}/bin/splunk' status 2>/dev/null | grep -q 'splunkd is running'"; then
    log "splunkd is running"
    break
  fi
  sleep 5
  waited=$(( waited + 5 ))
done
(( waited < 300 )) || fail "splunkd did not come up within 300s"

log "Performance tuning applied under natwest_demo_inputs/local/{limits,server}.conf"
