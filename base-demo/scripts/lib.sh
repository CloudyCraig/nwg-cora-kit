#!/usr/bin/env bash
# Common helpers for demo scripts. Source via: source "$(dirname "$0")/lib.sh"

set -Eeuo pipefail

SCRIPT_DIR_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[1]:-$0}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR_DEFAULT}/.." && pwd)"

export TERRAFORM_DIR="${REPO_ROOT}/terraform"
export HELM_CHART_DIR="${REPO_ROOT}/helm/natwest-payments"
export COLLECTOR_VALUES="${REPO_ROOT}/collector/values.yaml"
export APP_DIR="${REPO_ROOT}/app"
export TRAFFIC_DIR="${REPO_ROOT}/traffic-generator"

export SERVICE_NAMESPACE="${SERVICE_NAMESPACE:-natwest}"
export COLLECTOR_NAMESPACE="${COLLECTOR_NAMESPACE:-splunk-otel}"
export IMAGE_TAG="${IMAGE_TAG:-0.1.0}"

# Local-only env file for credentials (RUM token, realm, etc.). Gitignored
# (.env, .env.*) so secrets never enter source control. We auto-source it
# here so every script that pulls in lib.sh inherits the values. Existing
# environment wins (`set -a` exports without overriding pre-set vars).
if [[ -f "${REPO_ROOT}/.env" ]]; then
  # `set -a` makes every assignment in the sourced file exported. We snapshot
  # the previous nounset/errexit state because the .env file may legitimately
  # contain `KEY=` (empty) lines and we don't want to crash the parent script.
  set -a
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[%s] WARN:\033[0m %s\n' "$(date +%H:%M:%S)" "$*" 1>&2; }
fail() { printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "$(date +%H:%M:%S)" "$*" 1>&2; exit 1; }

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || fail "required command not found: $c"
  done
}

tf_output() {
  terraform -chdir="${TERRAFORM_DIR}" output -raw "$1"
}

# Resolve a usable Splunk Enterprise SSH key path.
#
# The repo writes the rendered private key to terraform/splunk-enterprise.pem
# via a local_file resource, but on macOS + OneDrive that path frequently
# materialises as a 387-byte cloud-only placeholder. ssh then either hangs
# for several seconds with "Operation timed out" or fails with a confusing
# "no key found" error, and the script chain stalls. This helper papers
# over that by recovering the key from terraform state when the on-disk
# copy isn't usable.
#
# Usage:
#   SSH_KEY="$(ensure_splunk_ssh_key "${SSH_KEY}")"
#
# Contract:
#   - Echoes a path to a usable private key on stdout (the input path if
#     it already validates, otherwise a freshly-extracted temp file).
#   - All progress/diagnostic output goes to stderr so the caller's
#     command substitution captures only the path.
#   - On a clean validation, the input path is returned unchanged.
#   - On recovery, a 0600-mode temp file is created under TMPDIR. The
#     caller is responsible for cleaning it up (we log the path so the
#     operator can `rm` it after the script finishes); not auto-deleted
#     because later scripts in the same shell may want to reuse it.
ensure_splunk_ssh_key() {
  local candidate="$1"
  local tmpkey

  # ssh-keygen -l fails cleanly (without hanging) on placeholder files
  # and non-key files, so it's a good "is this a real private key?" gate.
  if [[ -r "$candidate" ]] && ssh-keygen -l -f "$candidate" >/dev/null 2>&1; then
    printf '%s' "$candidate"
    return 0
  fi

  warn "SSH key at ${candidate} is unreadable or invalid (OneDrive cloud-only placeholder?); recovering from terraform state"
  require_cmd terraform jq

  tmpkey="$(mktemp -t splunk-enterprise.pem.XXXXXX)"
  chmod 600 "$tmpkey"

  # terraform state can be large; pipe to jq with -e so a missing
  # selector returns non-zero rather than writing the literal "null"
  # into the key file.
  if ! terraform -chdir="${TERRAFORM_DIR}" state pull 2>/dev/null \
       | jq -er '.resources[]
                 | select(.type=="tls_private_key" and .name=="splunk_enterprise")
                 | .instances[0].attributes.private_key_openssh' \
       > "$tmpkey"; then
    rm -f "$tmpkey"
    fail "Could not extract tls_private_key.splunk_enterprise from terraform state. Has the splunk_enterprise module been applied?"
  fi

  if ! ssh-keygen -l -f "$tmpkey" >/dev/null 2>&1; then
    rm -f "$tmpkey"
    fail "Extracted key from terraform state is not a valid OpenSSH private key."
  fi

  warn "recovered key written to ${tmpkey} (0600); remove it manually after the script chain finishes"
  printf '%s' "$tmpkey"
}
