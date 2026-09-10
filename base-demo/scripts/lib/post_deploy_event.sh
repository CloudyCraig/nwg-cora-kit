#!/usr/bin/env bash
# Emit a deploy/change event into both Splunk Observability and
# Splunk Enterprise so it shows up as:
#
#   * a vertical band on Splunk Observability time-series charts
#     (Custom Event annotation, /v2/event API) -- correlates with
#     APM / RUM / metric anomalies that follow the deploy.
#   * a structured record in Splunk Enterprise (`index=nwpay_audit
#     sourcetype=nwpay:demo_event event_type=deploy`) so the DORA
#     panels added in itsi/glass-table/natwest-payments-overview.xml
#     can include real (not just synthetic) deploys in their counts.
#
# Usage:
#   scripts/lib/post_deploy_event.sh --service api-gateway \
#       --version 0.1.4 --outcome success
#
# Optional flags:
#   --actor <name>            (default: $USER)
#   --duration-seconds <int>  (default: computed from $DEPLOY_START_EPOCH)
#   --lead-time-minutes <int> (default: 60)
#   --commit <sha>            (default: $GIT_SHA, fall back to short HEAD)
#
# Required env (any of the following may be skipped if you only want
# one side of the emission):
#   SPLUNK_REALM           - e.g. eu0 (enables o11y annotation)
#   SPLUNK_INGEST_TOKEN    - org-level INGEST token (NOT user API token)
#   SPLUNK_HEC_URL         - e.g. https://splunk.example.com:8088
#                             (enables Splunk Enterprise side)
#   SPLUNK_HEC_TOKEN       - HEC token with index=nwpay_audit access
#
# The script never fails the caller -- a failed event emit is logged
# to stderr and the script exits 0 so a `helm upgrade` post-install
# step can call it without risk of breaking the deploy.

set -Eeuo pipefail

SERVICE=""
VERSION=""
OUTCOME="success"           # success | failed | rolled_back
ACTOR="${USER:-ci-bot}"
DURATION_S=""
LEAD_TIME_MIN="60"
COMMIT_SHA="${GIT_SHA:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service)            SERVICE="$2";        shift 2;;
    --version)            VERSION="$2";        shift 2;;
    --outcome)            OUTCOME="$2";        shift 2;;
    --actor)              ACTOR="$2";          shift 2;;
    --duration-seconds)   DURATION_S="$2";     shift 2;;
    --lead-time-minutes)  LEAD_TIME_MIN="$2";  shift 2;;
    --commit)             COMMIT_SHA="$2";     shift 2;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# //;s/^#//'
      exit 0;;
    *)
      echo "post_deploy_event.sh: unknown flag '$1'" >&2
      exit 2;;
  esac
done

if [[ -z "$SERVICE" || -z "$VERSION" ]]; then
  echo "post_deploy_event.sh: --service and --version are required" >&2
  exit 2
fi

# Allow-list outcome (codeguard-0-input-validation-injection: closed
# enum at the trust boundary).
case "$OUTCOME" in
  success|failed|rolled_back) ;;
  *) echo "post_deploy_event.sh: --outcome must be one of: success failed rolled_back" >&2
     exit 2;;
esac

# Compute duration from $DEPLOY_START_EPOCH if not explicitly given.
if [[ -z "$DURATION_S" ]]; then
  if [[ -n "${DEPLOY_START_EPOCH:-}" ]]; then
    now=$(date +%s)
    DURATION_S=$(( now - DEPLOY_START_EPOCH ))
    [[ "$DURATION_S" -lt 0 ]] && DURATION_S=0
  else
    DURATION_S=120
  fi
fi

if [[ -z "$COMMIT_SHA" ]]; then
  if command -v git >/dev/null 2>&1 && git rev-parse --short HEAD >/dev/null 2>&1; then
    COMMIT_SHA="$(git rev-parse --short HEAD)"
  else
    COMMIT_SHA="unknown"
  fi
fi

DEPLOY_ID="dep-$(date +%Y%m%d%H%M%S)-${RANDOM}"
TS_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TS_MS="$(($(date +%s) * 1000))"

# ---- Splunk Observability event annotation -------------------------------
if [[ -n "${SPLUNK_REALM:-}" && -n "${SPLUNK_INGEST_TOKEN:-}" ]]; then
  # /v2/event posts a custom user-defined event type that shows up on
  # charts as a vertical band (Detector firings, Deployments, etc.).
  o11y_url="https://ingest.${SPLUNK_REALM}.signalfx.com/v2/event"
  body=$(cat <<EOF
[{"category":"USER_DEFINED",
  "eventType":"natwest.deployment",
  "timestamp": ${TS_MS},
  "dimensions":{
    "service":"${SERVICE}",
    "version":"${VERSION}",
    "environment":"demo",
    "deploy_id":"${DEPLOY_ID}",
    "outcome":"${OUTCOME}",
    "actor":"${ACTOR}",
    "commit":"${COMMIT_SHA}"
  },
  "properties":{
    "duration_seconds": ${DURATION_S},
    "lead_time_minutes": ${LEAD_TIME_MIN}
  }}]
EOF
)
  if curl -fsS --max-time 5 -X POST \
       -H "Content-Type: application/json" \
       -H "X-SF-TOKEN: ${SPLUNK_INGEST_TOKEN}" \
       --data "${body}" \
       "${o11y_url}" >/dev/null; then
    echo "[post-deploy] o11y annotation posted (deploy_id=${DEPLOY_ID})" >&2
  else
    echo "[post-deploy] WARNING: o11y annotation POST failed (non-fatal)" >&2
  fi
else
  echo "[post-deploy] SPLUNK_REALM / SPLUNK_INGEST_TOKEN not set, skipping o11y annotation" >&2
fi

# ---- Splunk Enterprise HEC event ----------------------------------------
if [[ -n "${SPLUNK_HEC_URL:-}" && -n "${SPLUNK_HEC_TOKEN:-}" ]]; then
  hec_body=$(cat <<EOF
{"time": $(date +%s), "host":"deploy-bot",
 "source":"post_deploy_event.sh", "sourcetype":"nwpay:demo_event",
 "index":"nwpay_audit",
 "event":{
   "@timestamp":"${TS_ISO}",
   "event_type":"deploy",
   "service":"${SERVICE}",
   "version":"${VERSION}",
   "deploy_id":"${DEPLOY_ID}",
   "outcome":"${OUTCOME}",
   "actor":"${ACTOR}",
   "duration_seconds": ${DURATION_S},
   "lead_time_minutes": ${LEAD_TIME_MIN},
   "commit":"${COMMIT_SHA}",
   "environment":"demo",
   "real_deploy": true
 }}
EOF
)
  if curl -fsS --max-time 5 -X POST \
       -H "Authorization: Splunk ${SPLUNK_HEC_TOKEN}" \
       -H "Content-Type: application/json" \
       --data "${hec_body}" \
       "${SPLUNK_HEC_URL%/}/services/collector/event" >/dev/null; then
    echo "[post-deploy] HEC event posted (deploy_id=${DEPLOY_ID})" >&2
  else
    echo "[post-deploy] WARNING: HEC event POST failed (non-fatal)" >&2
  fi
else
  echo "[post-deploy] SPLUNK_HEC_URL / SPLUNK_HEC_TOKEN not set, skipping HEC event" >&2
fi

echo "${DEPLOY_ID}"
