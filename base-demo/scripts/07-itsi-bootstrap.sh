#!/usr/bin/env bash
# Bootstrap the NatWest Payments ITSI service tree (services, entities, KPI
# base searches) on the demo Splunk Enterprise instance.
#
# Idempotent end-to-end: every object is upserted by deterministic _key.
# The Python helper does the JSON rendering; this wrapper handles connection
# wiring (port-forward via SSH if --remote, direct otherwise) and preflight.
#
# Required env (sourced from .env via lib.sh):
#   TF_VAR_splunk_enterprise_admin_password   Splunk admin password
#
# Optional env:
#   SPLUNK_ENTERPRISE_HOST   default itsi.splunk-observability.com
#   SSH_USER                 default ec2-user
#   SSH_KEY                  default <repo>/terraform/splunk-enterprise.pem
#   SPLUNK_ADMIN_USER        default admin
#   SPLUNK_MGMT_PORT         default 8089
#   ITSI_MANIFEST            default itsi/service-tree.yaml
#
# Flags:
#   --dry-run     render the JSON payloads to stdout, do not POST
#   --verbose     debug logging from the Python helper
#   --local       talk to localhost:8089 (e.g. when run from the EC2 itself)

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_cmd python3 ssh

SPLUNK_ENTERPRISE_HOST="${SPLUNK_ENTERPRISE_HOST:-itsi.splunk-observability.com}"
SSH_USER="${SSH_USER:-ec2-user}"
SSH_KEY="${SSH_KEY:-${REPO_ROOT}/terraform/splunk-enterprise.pem}"
SPLUNK_ADMIN_USER="${SPLUNK_ADMIN_USER:-admin}"
SPLUNK_MGMT_PORT="${SPLUNK_MGMT_PORT:-8089}"
ITSI_MANIFEST="${ITSI_MANIFEST:-${REPO_ROOT}/itsi/service-tree.yaml}"

DRY_RUN=0
VERBOSE=0
USE_LOCAL=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    --verbose) VERBOSE=1 ;;
    --local)   USE_LOCAL=1 ;;
    -h|--help)
      sed -n '1,30p' "$0"
      exit 0
      ;;
    *) fail "unknown flag: ${arg}" ;;
  esac
done

[[ -f "${ITSI_MANIFEST}" ]] || fail "ITSI manifest not found: ${ITSI_MANIFEST}"

# PyYAML is the only third-party dep; check up front.
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  fail "PyYAML is required. Install with: python3 -m pip install --user pyyaml"
fi

PY_HELPER="${SCRIPT_DIR}/lib/itsi_bootstrap.py"
[[ -f "${PY_HELPER}" ]] || fail "helper not found: ${PY_HELPER}"

# ---------------------------------------------------------------------------
# Dry-run path - no SSH, no auth required.
# ---------------------------------------------------------------------------
if (( DRY_RUN )); then
  # In dry-run we redirect log lines to stderr so the JSON on stdout stays
  # parseable by jq / python -m json.tool / etc.
  log "dry-run: rendering manifest to stdout (no API calls)" >&2
  exec python3 "${PY_HELPER}" \
        --manifest "${ITSI_MANIFEST}" \
        ${VERBOSE:+--verbose} \
        --dry-run
fi

: "${TF_VAR_splunk_enterprise_admin_password:?Set TF_VAR_splunk_enterprise_admin_password (in .env or environment)}"

# ---------------------------------------------------------------------------
# Connection: either talk to localhost:8089 directly (--local) or open an SSH
# tunnel from a free local port to the EC2 management port. The tunnel is the
# default because the splunkd management interface is bound to the loopback /
# private subnet only, not exposed via the public Security Group.
# ---------------------------------------------------------------------------
LOCAL_PORT="${SPLUNK_MGMT_PORT}"
TUNNEL_PID=""
cleanup() {
  if [[ -n "${TUNNEL_PID}" ]]; then
    kill "${TUNNEL_PID}" 2>/dev/null || true
    wait "${TUNNEL_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if (( ! USE_LOCAL )); then
  SSH_KEY="$(ensure_splunk_ssh_key "${SSH_KEY}")"
  chmod 600 "${SSH_KEY}" 2>/dev/null || true

  # Find a free local port in the 18089-18198 range.
  for p in $(seq 18089 18198); do
    if ! (echo > "/dev/tcp/127.0.0.1/${p}") >/dev/null 2>&1; then
      LOCAL_PORT="${p}"
      break
    fi
  done

  log "opening SSH tunnel 127.0.0.1:${LOCAL_PORT} -> ${SPLUNK_ENTERPRISE_HOST}:${SPLUNK_MGMT_PORT}"
  ssh -i "${SSH_KEY}" \
      -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" \
      -o ServerAliveInterval=30 \
      -o BatchMode=yes \
      -fN \
      -L "${LOCAL_PORT}:127.0.0.1:${SPLUNK_MGMT_PORT}" \
      "${SSH_USER}@${SPLUNK_ENTERPRISE_HOST}" </dev/null
  # `ssh -f` daemonises so we cannot capture its PID directly. Use pgrep
  # against the exact local-port spec.
  TUNNEL_PID="$(pgrep -f "ssh.*-L ${LOCAL_PORT}:127.0.0.1:${SPLUNK_MGMT_PORT}.*${SSH_USER}@${SPLUNK_ENTERPRISE_HOST}" | head -1 || true)"
  [[ -n "${TUNNEL_PID}" ]] || warn "could not capture tunnel PID; cleanup may not kill it"

  # Wait up to 10 s for the tunnel to be ready.
  for _ in $(seq 1 20); do
    if (echo > "/dev/tcp/127.0.0.1/${LOCAL_PORT}") >/dev/null 2>&1; then
      break
    fi
    sleep 0.5
  done

  TARGET_HOST="127.0.0.1"
else
  TARGET_HOST="${SPLUNK_ENTERPRISE_HOST}"
fi

log "running ITSI bootstrap (host=${TARGET_HOST}:${LOCAL_PORT}, manifest=${ITSI_MANIFEST})"
python3 "${PY_HELPER}" \
  --manifest "${ITSI_MANIFEST}" \
  --host     "${TARGET_HOST}" \
  --port     "${LOCAL_PORT}" \
  --user     "${SPLUNK_ADMIN_USER}" \
  --password "${TF_VAR_splunk_enterprise_admin_password}" \
  ${VERBOSE:+--verbose}

log "ITSI bootstrap complete"
log "  Splunk Web: https://${SPLUNK_ENTERPRISE_HOST}:8000/en-US/app/itsi/service_analyzer"
