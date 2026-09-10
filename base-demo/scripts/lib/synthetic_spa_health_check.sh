#!/usr/bin/env bash
# Create-or-update a Splunk Synthetics API check that polls SPA readiness:
# GET {origin}/healthz (nginx returns 200 + body "ok"). Lightweight alternative
# to the browser synthetic for pure availability / fast polling.
#
# Required env vars:
#   SPLUNK_REALM               - e.g. us0, eu0
#   SPLUNK_API_TOKEN           - user-level API token (NOT the ingest token)
#   SYNTHETIC_SPA_HEALTH_URL   - e.g. https://itsi.example.com/healthz
# Optional env vars:
#   SYNTHETIC_NAME             - default: [NatWest demo] SPA health
#   SYNTHETIC_FREQUENCY        - seconds (default 60)
#   SYNTHETIC_LOCATIONS        - JSON array (default: ["aws-eu-west-1"])

set -Eeuo pipefail

: "${SPLUNK_REALM:?SPLUNK_REALM must be set (e.g. us0, eu0)}"
: "${SPLUNK_API_TOKEN:?SPLUNK_API_TOKEN must be set (Splunk user API token, not the ingest token)}"
: "${SYNTHETIC_SPA_HEALTH_URL:?SYNTHETIC_SPA_HEALTH_URL must be set (public SPA /healthz URL)}"

SYNTHETIC_NAME="${SYNTHETIC_NAME:-[NatWest demo] SPA health}"
SYNTHETIC_FREQUENCY="${SYNTHETIC_FREQUENCY:-60}"
SYNTHETIC_LOCATIONS="${SYNTHETIC_LOCATIONS:-[\"aws-eu-west-1\"]}"
# Synthetic "device" profile (GET /v2/synthetics/devices). Default Desktop = 1.
SYNTHETIC_DEVICE_ID="${SYNTHETIC_DEVICE_ID:-1}"

# Splunk Observability Synthetics (current API): list GET /v2/synthetics/tests,
# create/update API checks POST/PUT /v2/synthetics/tests/api (see splunk/syntheticsclient).
SYN_BASE="https://api.${SPLUNK_REALM}.signalfx.com/v2/synthetics"
API_LIST_GET="${SYN_BASE}/tests"
API_TESTS_API="${SYN_BASE}/tests/api"

read -r -d '' BODY <<'JSON' || true
{
  "test": {
    "active": true,
    "deviceId": __SYNTHETIC_DEVICE_ID__,
    "frequency": __SYNTHETIC_FREQUENCY__,
    "locationIds": __SYNTHETIC_LOCATIONS__,
    "name": "__SYNTHETIC_NAME__",
    "schedulingStrategy": "round_robin",
    "automaticRetries": 0,
    "requests": [
      {
        "configuration": {
          "name": "GET SPA /healthz",
          "requestMethod": "GET",
          "url": "__SYNTHETIC_SPA_HEALTH_URL__",
          "body": "",
          "headers": {}
        },
        "setup": [],
        "validations": [
          {
            "name": "HTTP status is 200",
            "type": "assert_numeric",
            "actual": "{{response.code}}",
            "expected": "200",
            "comparator": "equals"
          },
          {
            "name": "Body contains ok",
            "type": "assert_string",
            "actual": "{{response.body}}",
            "expected": "ok",
            "comparator": "contains"
          }
        ]
      }
    ]
  }
}
JSON

BODY="${BODY//__SYNTHETIC_NAME__/${SYNTHETIC_NAME}}"
BODY="${BODY//__SYNTHETIC_FREQUENCY__/${SYNTHETIC_FREQUENCY}}"
BODY="${BODY//__SYNTHETIC_LOCATIONS__/${SYNTHETIC_LOCATIONS}}"
BODY="${BODY//__SYNTHETIC_SPA_HEALTH_URL__/${SYNTHETIC_SPA_HEALTH_URL}}"
BODY="${BODY//__SYNTHETIC_DEVICE_ID__/${SYNTHETIC_DEVICE_ID}}"

auth_header=("-H" "X-SF-TOKEN: ${SPLUNK_API_TOKEN}")
content_header=("-H" "Content-Type: application/json")

echo "[synthetic-spa-health] looking up existing check named '${SYNTHETIC_NAME}'"
existing=$(curl -gfsS "${auth_header[@]}" "${API_LIST_GET}?limit=5000" || echo '{}')
existing_id=$(printf '%s' "${existing}" | SYNTHETIC_NAME="${SYNTHETIC_NAME}" python3 -c '
import json, sys, os
try:
    body = json.load(sys.stdin)
except Exception:
    sys.exit(0)
items = body.get("results") or body.get("tests") or []
target = ""
name = os.environ.get("SYNTHETIC_NAME", "")
for it in items:
    if it.get("name") == name and it.get("type") == "api":
        target = str(it.get("id") or it.get("testId") or "")
        break
print(target)
' 2>/dev/null || true)

if [[ -n "${existing_id}" ]]; then
  echo "[synthetic-spa-health] updating existing check id=${existing_id}"
  curl -gfsS -X PUT "${API_TESTS_API}/${existing_id}" \
    "${auth_header[@]}" "${content_header[@]}" \
    --data "${BODY}" >/dev/null
else
  echo "[synthetic-spa-health] creating new check"
  curl -gfsS -X POST "${API_TESTS_API}" \
    "${auth_header[@]}" "${content_header[@]}" \
    --data "${BODY}" >/dev/null
fi

echo "[synthetic-spa-health] done"
