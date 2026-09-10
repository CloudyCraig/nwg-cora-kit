#!/usr/bin/env bash
# scripts/05e-create-spa-obs-resources.sh
#
# Create (or update) the three SPA-specific Splunk Observability Cloud
# resources via the SignalFx REST API:
#
#   1. signalfx_detector.bronze_spa_failure_rate     - SPA-perceived
#                                                      payment failure rate
#                                                      for customer.tier=bronze
#                                                      (>10% for 3m -> Critical,
#                                                       >5% for 5m -> Warning).
#   2. signalfx_time_chart.spa_payment_outcome_by_tier - RUM funnel of
#                                                      payment.outcome
#                                                      grouped by customer.tier.
#   3. signalfx_time_chart.spa_p95_by_network_type   - p95 client-perceived
#                                                      duration of
#                                                      payment.completed spans
#                                                      grouped by the browser's
#                                                      network.effective_type.
#
# Plus binds both new charts onto the existing
# `[NatWest demo] Payments Operations` dashboard at row 12.
#
# Why this script exists alongside `terraform apply`:
#   The Terraform definitions live in terraform/observability.tf and
#   terraform/dashboard.tf. `terraform apply` is the canonical path. This
#   shell-level fallback exists for two scenarios:
#
#     a) The aws_instance.splunk_enterprise.user_data validator is blocking
#        ALL `terraform apply` runs. The validator runs on every plan
#        regardless of -target, so even an SignalFx-only change can't get
#        through. The fix lives in splunk_enterprise.tf
#        (user_data_base64 + base64gzip), but if your branch is older than
#        that and you can't pick the change up, this script gets the
#        Observability resources live without touching Terraform.
#
#     b) The signalfx provider's notification format for webhook
#        integrations sometimes drifts between provider versions, blocking
#        in-place detector updates. Creating via REST sets notifications=[]
#        which always works; you can wire ITSI alert bridge notifications
#        in the Splunk UI afterwards.
#
# Idempotent: each create is preceded by a search for an existing object
# with the same name; if found, we PUT instead of POST so re-runs do not
# duplicate. The dashboard rebind merges new chart entries into the
# existing chart list rather than replacing it.
#
# State drift caveat: when this script is used as a fallback (not via
# `terraform apply`), Terraform does NOT know about the resources it
# creates. Once the upstream blocker is cleared, run:
#
#   terraform import 'signalfx_detector.bronze_spa_failure_rate[0]'      <id>
#   terraform import 'signalfx_time_chart.spa_payment_outcome_by_tier[0]' <id>
#   terraform import 'signalfx_time_chart.spa_p95_by_network_type[0]'    <id>
#
# (the script prints the IDs at the end). If you applied through Terraform
# instead, this script is a no-op except for in-place updates that stay
# byte-identical to the Terraform spec.
#
# Required env (mirrors scripts/05d-promote-metricsets.sh):
#   SPLUNK_REALM     - e.g. eu0, us0, us1
#   SPLUNK_API_TOKEN - USER API token (NOT the ingest token). The account
#                      behind it must have the admin role; power and
#                      read_only cannot mutate detectors / dashboards.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_cmd python3

missing_env=()
[[ -z "${SPLUNK_REALM:-}"     ]] && missing_env+=("SPLUNK_REALM")
[[ -z "${SPLUNK_API_TOKEN:-}" ]] && missing_env+=("SPLUNK_API_TOKEN")
if [[ ${#missing_env[@]} -gt 0 ]]; then
  fail "missing env: ${missing_env[*]}. Set SPLUNK_REALM (e.g. eu0) and SPLUNK_API_TOKEN (USER API token, NOT the ingest token)."
fi

log "creating SPA Observability resources via REST against api.${SPLUNK_REALM}.signalfx.com"
exec python3 "${SCRIPT_DIR}/lib/spa_obs_rest.py"
