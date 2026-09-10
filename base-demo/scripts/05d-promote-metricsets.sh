#!/usr/bin/env bash
# scripts/05d-promote-metricsets.sh
#
# Promote the demo's business span attributes (customer.tier,
# customer.location, payment.scheme, payment.roaming, ...) to APM
# MetricSets so they appear in:
#
#   * Service Map -> Breakdown / Add filters
#   * Tag Spotlight pivots
#   * Detectors and dashboards keyed by those tags (Monitoring MetricSets only)
#
# IMPORTANT - this is a best-effort wrapper. Splunk Observability Cloud
# does NOT currently expose a supported public REST API or Terraform
# resource for managing APM MetricSets - they are UI-managed only (see
# https://help.splunk.com/en/splunk-observability-cloud/monitor-application-performance/analyze-services-with-span-tags-and-metricsets/learn-about-troubleshooting-metricsets/use-and-manage-troubleshooting-metricsets).
#
# This script tries a small set of undocumented internal endpoints that
# the in-product UI uses. If the tenant accepts them, you save ~5 min
# of clicking. If the endpoints have moved (they may, without notice),
# the script prints a click-by-click runbook so you can finish in the
# UI - docs/operations/metricsets.md has the same content.
#
# Required env:
#   SPLUNK_REALM        - e.g. eu0, us0, us1
#   SPLUNK_API_TOKEN    - USER API token (NOT the ingest token). The
#                         account behind it must have the
#                         admin role; power and read_only cannot mutate
#                         MetricSets.
#
# Optional env:
#   METRICSETS_FILE     - canonical list (default: scripts/lib/metricsets.json)
#   METRICSETS_DRY_RUN  - "1" to skip the API attempt and just print the runbook
#   METRICSETS_ENDPOINT - override the candidate endpoint (path after the host)

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_cmd curl jq

METRICSETS_FILE="${METRICSETS_FILE:-${SCRIPT_DIR}/lib/metricsets.json}"
[[ -f "${METRICSETS_FILE}" ]] || fail "MetricSets config not found: ${METRICSETS_FILE}"

# This script is advisory. If the operator hasn't set up a user API
# token yet (or didn't pin SPLUNK_REALM), we still print the runbook so
# they have an actionable next step rather than a stack trace. Exit 0
# so the wrapper bootstrap doesn't abort on an optional step.
missing_env=()
[[ -z "${SPLUNK_REALM:-}"     ]] && missing_env+=("SPLUNK_REALM")
[[ -z "${SPLUNK_API_TOKEN:-}" ]] && missing_env+=("SPLUNK_API_TOKEN")
if [[ ${#missing_env[@]} -gt 0 ]]; then
  warn "missing env: ${missing_env[*]}. Skipping the API attempt and printing the manual runbook."
  warn "Set SPLUNK_REALM (e.g. eu0) and SPLUNK_API_TOKEN (user API token, NOT the ingest token) to enable the API path."
  METRICSETS_DRY_RUN=1
fi

DRY_RUN="${METRICSETS_DRY_RUN:-0}"

# Candidate endpoints, in order of preference. These are the historical
# internal paths the Splunk Observability UI has used; if a tenant has
# been moved to a new path you can override with METRICSETS_ENDPOINT.
#
# IMPORTANT (probed May 2026 on api.eu0.signalfx.com):
#   - /v2/apm/topology/metricset       still resolves (POST), but it is
#                                      now a TOPOLOGY SEARCH endpoint
#                                      that returns Service Map slices,
#                                      not a MetricSet management
#                                      endpoint. Sending a create-style
#                                      body returns
#                                        400 "timeRange is required"
#                                      because the controller deserialises
#                                      the body into TopologySearchInput.
#                                      We treat that exact 400 as a hard
#                                      signal that the endpoint is NOT
#                                      the management endpoint and skip
#                                      it.
#   - /v2/apm/custom/metricset         404
#   - /v2/apm/metricset                404
#   - /v2/apm/troubleshooting-metricset 404
#   - /v2/apm/monitoring-metricset     404
#   - /v2/apm/spanTag                  404
# Net: there is currently NO exposed CRUD endpoint; MetricSets are
# strictly UI-managed (Settings -> APM & RUM MetricSets). The probe
# loop is preserved on the off-chance Splunk re-exposes one of these
# paths in a future release, but the practical path is the runbook.
declare -a CANDIDATE_ENDPOINTS
if [[ -n "${METRICSETS_ENDPOINT:-}" ]]; then
  CANDIDATE_ENDPOINTS=( "${METRICSETS_ENDPOINT}" )
else
  CANDIDATE_ENDPOINTS=(
    "/v2/apm/topology/metricset"
    "/v2/apm/custom/metricset"
    "/v2/apm/metricset"
  )
fi

# Markers in the response body that prove the endpoint is the
# Topology Search controller (TopologySearchInput) rather than a
# MetricSet management endpoint. When we see these, we know the
# create-style POST cannot succeed against this path regardless of
# the body we send, so the script bails to the manual runbook
# immediately rather than retrying 9 times.
TOPOLOGY_SEARCH_MARKERS=(
  "TopologySearchInput"
  "timeRange is required"
  "Invalid delimiter used to split time range"
)

API_BASE="https://api.${SPLUNK_REALM}.signalfx.com"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
STATUS_OK=()
STATUS_FAIL=()
STATUS_SKIP=()

print_runbook() {
  local n_fail=$1
  cat <<'RUNBOOK'

============================================================================
 MANUAL UI RUNBOOK - run for any MetricSet the API path could not confirm
============================================================================

 1. In the Splunk Observability Cloud sidebar, click the gear / Settings
    icon (bottom-left) -> Settings -> APM & RUM MetricSets.
    (On some tenants: Data Management -> APM -> MetricSets - same dialog.)

 2. Click 'New MetricSet' (top-right).

 3. For each MetricSet listed below:
       Span tag                 [paste the spanTag column]
       Troubleshooting          [tick if 'troubleshooting: true' below]
       Monitoring               [tick if 'monitoring: true' below]
       Scope                    Leave at default (all services).

 4. Click Save. New traces are indexed immediately; existing traces
    backfill in ~3-5 minutes.

 5. Verify: open Service Map, click Breakdown - the tag should appear in
    alphabetical order. If not after 5 minutes, refresh the page.

 Canonical list (single source of truth):
    scripts/lib/metricsets.json
 Companion runbook with screenshots / commentary:
    docs/operations/metricsets.md

----------------------------------------------------------------------------
RUNBOOK

  jq -r '.metricsets[] | "  - " + .spanTag + "    [TMS=" + (.troubleshooting|tostring) + ", MMS=" + (.monitoring|tostring) + "]    " + .why' "${METRICSETS_FILE}"
  echo ""
  echo "============================================================================"
  if (( n_fail > 0 )); then
    warn "${n_fail} MetricSet(s) could not be created via the internal API. Run through the UI runbook above to finish."
  fi
}

# ---------------------------------------------------------------------------
# API probing
# ---------------------------------------------------------------------------
# Pick the first endpoint that doesn't immediately 404 on a probe. We use
# a HEAD-style GET against the collection root; if Splunk returns 405
# (method not allowed) or 200/204 we consider the path live. 404 means
# the endpoint has been retired in this tenant.
WORKING_ENDPOINT=""
probe_endpoints() {
  if (( DRY_RUN == 1 )); then
    log "METRICSETS_DRY_RUN=1 - skipping API probe."
    return
  fi
  for ep in "${CANDIDATE_ENDPOINTS[@]}"; do
    url="${API_BASE}${ep}"
    code=$(curl -sS -o /dev/null -m 8 \
                 -w '%{http_code}' \
                 -H "X-SF-Token: ${SPLUNK_API_TOKEN}" \
                 -H "Accept: application/json" \
                 "${url}" 2>/dev/null || echo "000")
    case "${code}" in
      200|204|400|401|403|405|422)
        WORKING_ENDPOINT="${ep}"
        log "candidate endpoint ${ep} responded HTTP ${code} - using it for POST."
        return
        ;;
      404)
        warn "candidate endpoint ${ep} returned 404 - tenant doesn't expose this path."
        ;;
      000)
        warn "candidate endpoint ${ep} did not respond (network / DNS). Skipping."
        ;;
      *)
        warn "candidate endpoint ${ep} returned HTTP ${code} - treating as unavailable."
        ;;
    esac
  done
}

# Build a JSON payload for one MetricSet. The exact field names vary
# between internal endpoint versions; we send the union of historically
# accepted fields and let the server ignore what it doesn't recognise.
build_payload() {
  local span_tag="$1" tms="$2" mms="$3"
  jq -n \
     --arg tag "${span_tag}" \
     --argjson tms "${tms}" \
     --argjson mms "${mms}" \
     '{
        spanTag:        $tag,
        tag:            $tag,
        name:           $tag,
        scope:          { kind: "ALL" },
        enableTroubleshootingMetricSet: $tms,
        troubleshootingMetricSet:       $tms,
        enableMonitoringMetricSet:      $mms,
        monitoringMetricSet:            $mms
      }'
}

# Test whether the response body matches one of the known signatures
# that prove the endpoint is the topology-search controller, not a
# MetricSet management endpoint. Used to bail out early and steer the
# operator to the runbook instead of issuing 9 doomed POSTs.
is_topology_search_response() {
  local body="$1" marker
  for marker in "${TOPOLOGY_SEARCH_MARKERS[@]}"; do
    if [[ "${body}" == *"${marker}"* ]]; then
      return 0
    fi
  done
  return 1
}

# Set when we have proof the only working candidate endpoint is in
# fact the topology-search controller. Triggers early-exit of the
# main loop so we don't fire a futile POST per MetricSet.
ENDPOINT_IS_SEARCH_ONLY=0

# Try to create one MetricSet. Returns 0 on success, 1 on confirmed
# failure. We treat 409 (conflict / already exists) as success because
# the operator just wants the MetricSet to exist.
post_metricset() {
  local payload="$1" span_tag="$2"
  local url="${API_BASE}${WORKING_ENDPOINT}"
  local tmp; tmp="$(mktemp)"
  local code
  code=$(curl -sS -o "${tmp}" -m 12 \
              -w '%{http_code}' \
              -X POST \
              -H "X-SF-Token: ${SPLUNK_API_TOKEN}" \
              -H "Content-Type: application/json" \
              -H "Accept: application/json" \
              --data "${payload}" \
              "${url}" 2>/dev/null || echo "000")
  local body
  body="$(head -c 400 "${tmp}" 2>/dev/null || true)"
  rm -f "${tmp}"
  case "${code}" in
    200|201|202|204)
      log "${span_tag}    OK (HTTP ${code})"
      return 0
      ;;
    409)
      log "${span_tag}    already exists (HTTP 409) - skipping"
      return 0
      ;;
    400)
      # Treat the topology-search 400 signature as a hard signal: the
      # endpoint exists but is the wrong shape, no point trying again
      # for the remaining MetricSets in the list.
      if is_topology_search_response "${body}"; then
        ENDPOINT_IS_SEARCH_ONLY=1
        warn "${span_tag}    endpoint is a topology-search controller, not a MetricSet management endpoint (Splunk has not exposed a CRUD API in this tenant). Skipping the rest of the list and printing the UI runbook."
        return 1
      fi
      warn "${span_tag}    failed (HTTP ${code}): ${body}"
      return 1
      ;;
    *)
      warn "${span_tag}    failed (HTTP ${code}): ${body}"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log "promoting span attributes to APM MetricSets (best effort)"
log "realm=${SPLUNK_REALM}  config=${METRICSETS_FILE}"

if (( DRY_RUN == 0 )); then
  probe_endpoints
fi

if (( DRY_RUN == 0 )) && [[ -n "${WORKING_ENDPOINT}" ]]; then
  log "found candidate endpoint: ${API_BASE}${WORKING_ENDPOINT}"

  # Iterate the canonical list with jq, one MetricSet per line.
  # Bail out the moment we identify the endpoint as topology-search-only
  # so we don't pollute the operator's terminal with 9 identical stack
  # traces. Everything after the bail-out is reported as "skipped (no
  # API path)" so it shows up in the runbook list.
  REMAINING_AFTER_BAILOUT=()
  while IFS=$'\t' read -r span_tag tms mms; do
    if (( ENDPOINT_IS_SEARCH_ONLY == 1 )); then
      REMAINING_AFTER_BAILOUT+=("${span_tag}")
      continue
    fi
    payload="$(build_payload "${span_tag}" "${tms}" "${mms}")"
    if post_metricset "${payload}" "${span_tag}"; then
      STATUS_OK+=("${span_tag}")
    else
      if (( ENDPOINT_IS_SEARCH_ONLY == 1 )); then
        # post_metricset just flipped the flag; the MetricSet that
        # tripped the detection itself is a skip, not a hard failure.
        STATUS_SKIP+=("${span_tag}")
      else
        STATUS_FAIL+=("${span_tag}")
      fi
    fi
  done < <(jq -r '.metricsets[] | [.spanTag, (.troubleshooting|tostring), (.monitoring|tostring)] | @tsv' "${METRICSETS_FILE}")
  if (( ${#REMAINING_AFTER_BAILOUT[@]} > 0 )); then
    for span_tag in "${REMAINING_AFTER_BAILOUT[@]}"; do
      STATUS_SKIP+=("${span_tag}")
    done
  fi
else
  if (( DRY_RUN == 1 )); then
    log "dry run - skipped API calls"
  else
    warn "no internal MetricSet endpoint responded - falling back to manual runbook."
  fi
  # Treat every entry as "skipped" so the runbook prints the full list.
  while IFS=$'\t' read -r span_tag _ _; do
    STATUS_SKIP+=("${span_tag}")
  done < <(jq -r '.metricsets[] | [.spanTag, (.troubleshooting|tostring), (.monitoring|tostring)] | @tsv' "${METRICSETS_FILE}")
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
log "summary"
log "  created / already-existed : ${#STATUS_OK[@]}"
log "  failed                    : ${#STATUS_FAIL[@]}"
log "  skipped (no API path)     : ${#STATUS_SKIP[@]}"

if [[ ${#STATUS_FAIL[@]} -gt 0 ]]; then
  log "  failed list               : ${STATUS_FAIL[*]}"
fi
if [[ ${#STATUS_SKIP[@]} -gt 0 ]]; then
  log "  skipped list              : ${STATUS_SKIP[*]}"
fi

# Always print the runbook when something is outstanding. It's harmless
# (it's just text), and we'd rather be redundant than leave the operator
# guessing about what to do next.
needs_runbook=$(( ${#STATUS_FAIL[@]} + ${#STATUS_SKIP[@]} ))
if (( needs_runbook > 0 )); then
  print_runbook "${needs_runbook}"
  # Exit 0 anyway - this script is advisory, the demo can still run
  # while the operator finishes in the UI.
fi

log "done. Wait 3-5 minutes after creating MetricSets for the backfill, then refresh Service Map -> Breakdown."
