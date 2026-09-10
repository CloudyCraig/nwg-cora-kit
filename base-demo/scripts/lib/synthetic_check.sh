#!/usr/bin/env bash
# Create-or-update a Splunk Synthetics API check via the v2 REST API.
#
# Splunk Synthetics is not currently exposed via the splunk-terraform/signalfx
# provider, so this script wraps the Synthetics REST API to keep the demo
# fully scriptable. Idempotent: looks up an existing check by name and PUTs
# updates if found, else POSTs a new check.
#
# Required env vars:
#   SPLUNK_REALM          - e.g. us0, us1, eu0
#   SPLUNK_API_TOKEN      - user-level API token (NOT the ingest token)
#   SYNTHETIC_TARGET_URL  - https://gateway.example.com/api/v1/payments/process
# Optional env vars:
#   SYNTHETIC_NAME        - human-readable check name (default: NatWest payments gateway)
#   SYNTHETIC_FREQUENCY   - poll interval seconds (default 60)
#   SYNTHETIC_LOCATIONS   - JSON array of location ids (default: ["aws-eu-west-1"])

set -Eeuo pipefail

: "${SPLUNK_REALM:?SPLUNK_REALM must be set (e.g. us0, eu0)}"
: "${SPLUNK_API_TOKEN:?SPLUNK_API_TOKEN must be set (Splunk user API token, not the ingest token)}"
: "${SYNTHETIC_TARGET_URL:?SYNTHETIC_TARGET_URL must be set (api-gateway public URL ending in /process)}"

SYNTHETIC_NAME="${SYNTHETIC_NAME:-NatWest payments gateway}"
SYNTHETIC_FREQUENCY="${SYNTHETIC_FREQUENCY:-60}"
SYNTHETIC_LOCATIONS="${SYNTHETIC_LOCATIONS:-[\"aws-eu-west-1\"]}"
SYNTHETIC_DEVICE_ID="${SYNTHETIC_DEVICE_ID:-1}"

# List: GET /v2/synthetics/tests  |  API check: POST/PUT /v2/synthetics/tests/api
SYN_BASE="https://api.${SPLUNK_REALM}.signalfx.com/v2/synthetics"
API_LIST_GET="${SYN_BASE}/tests"
API_TESTS_API="${SYN_BASE}/tests/api"

# Probe payload mirrors what the traffic generator sends, so the
# synthetic check exercises the same end-to-end path. Asserts a
# 200 status and that the response body contains a payment_id.
#
# customer_id / customer_tier are baked in as Bronze (Olivia, cust-uk-001)
# deliberately: the synthetic acts as the canary for the
# `incident.sh inject-tier-throttle bronze` story. When that scenario
# fires, the synthetic starts returning 429 from api-gateway, the test
# goes red, and the Bronze-decline detector lights up - all from the
# same trace.
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
          "name": "submit FPS payment",
          "requestMethod": "POST",
          "url": "__SYNTHETIC_TARGET_URL__",
          "headers": {"Content-Type": "application/json"},
          "body": "{\"payment_id\":\"synthetic-{{guid}}\",\"scheme\":\"FPS\",\"amount_minor_units\":2500,\"currency\":\"GBP\",\"debtor_country\":\"GB\",\"creditor_country\":\"GB\",\"channel\":\"web\",\"customer_id\":\"cust-uk-001\",\"customer_tier\":\"bronze\"}"
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
            "name": "payment_id in body",
            "type": "assert_string",
            "actual": "{{response.body}}",
            "expected": "payment_id",
            "comparator": "contains"
          }
        ]
      }
    ]
  }
}
JSON

# Substitute placeholders. Done outside the heredoc so the shell doesn't
# try to expand the {{guid}} synthetics template variable.
BODY="${BODY//__SYNTHETIC_NAME__/${SYNTHETIC_NAME}}"
BODY="${BODY//__SYNTHETIC_FREQUENCY__/${SYNTHETIC_FREQUENCY}}"
BODY="${BODY//__SYNTHETIC_LOCATIONS__/${SYNTHETIC_LOCATIONS}}"
BODY="${BODY//__SYNTHETIC_TARGET_URL__/${SYNTHETIC_TARGET_URL}}"
BODY="${BODY//__SYNTHETIC_DEVICE_ID__/${SYNTHETIC_DEVICE_ID}}"

auth_header=("-H" "X-SF-TOKEN: ${SPLUNK_API_TOKEN}")
content_header=("-H" "Content-Type: application/json")

echo "[synthetic-api] looking up existing check named '${SYNTHETIC_NAME}'"
# -g disables curl URL globbing so literal [ and ] in the name don't get
# interpreted as a range expression (curl error 3).
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
  echo "[synthetic-api] updating existing check id=${existing_id}"
  curl -gfsS -X PUT "${API_TESTS_API}/${existing_id}" \
    "${auth_header[@]}" "${content_header[@]}" \
    --data "${BODY}" >/dev/null
else
  echo "[synthetic-api] creating new check"
  curl -gfsS -X POST "${API_TESTS_API}" \
    "${auth_header[@]}" "${content_header[@]}" \
    --data "${BODY}" >/dev/null
fi

echo "[synthetic-api] done"
