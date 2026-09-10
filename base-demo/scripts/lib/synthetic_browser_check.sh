#!/usr/bin/env bash
# Create-or-update a Splunk Synthetics BROWSER check via the v2 REST API.
#
# Companion to synthetic_check.sh (which provisions the API check). The
# browser check is a real headless-Chromium navigation that loads the
# SPA login page and asserts the username field exists (`assert_element_present`) — a stronger
# signal than the API probe because it exercises CDN/CDN-WAF/SPA/CSS/JS
# end-to-end in addition to the gateway.
#
# Required env vars:
#   SPLUNK_REALM           - e.g. us0, us1, eu0
#   SPLUNK_API_TOKEN       - user-level API token (NOT the ingest token)
#   SYNTHETIC_BROWSER_URL  - https://itsi.splunk-observability.com/login
# Optional env vars:
#   SYNTHETIC_NAME         - default: NatWest payments SPA
#   SYNTHETIC_FREQUENCY    - poll interval seconds (default 300; browser
#                            tests are billed per device-minute and the
#                            API check already covers the high-frequency
#                            availability story)
#   SYNTHETIC_LOCATIONS    - JSON array (default: ["aws-eu-west-1"])

set -Eeuo pipefail

: "${SPLUNK_REALM:?SPLUNK_REALM must be set (e.g. us0, eu0)}"
: "${SPLUNK_API_TOKEN:?SPLUNK_API_TOKEN must be set (Splunk user API token, not the ingest token)}"
: "${SYNTHETIC_BROWSER_URL:?SYNTHETIC_BROWSER_URL must be set (e.g. https://itsi.splunk-observability.com/login)}"

SYNTHETIC_NAME="${SYNTHETIC_NAME:-NatWest payments SPA}"
SYNTHETIC_FREQUENCY="${SYNTHETIC_FREQUENCY:-300}"
SYNTHETIC_LOCATIONS="${SYNTHETIC_LOCATIONS:-[\"aws-eu-west-1\"]}"
SYNTHETIC_DEVICE_ID="${SYNTHETIC_DEVICE_ID:-1}"

# BrowserCheckV2: startUrl is host + path without scheme; urlProtocol is e.g. "https://"
BR_URL="${SYNTHETIC_BROWSER_URL}"
if [[ "${BR_URL}" =~ ^https:// ]]; then
  URL_PROTOCOL="https://"
elif [[ "${BR_URL}" =~ ^http:// ]]; then
  URL_PROTOCOL="http://"
else
  URL_PROTOCOL="https://"
  BR_URL="https://${BR_URL}"
fi
START_NO_PROTO="${BR_URL#*://}"

SYN_BASE="https://api.${SPLUNK_REALM}.signalfx.com/v2/synthetics"
API_LIST_GET="${SYN_BASE}/tests"
API_TESTS_BROWSER="${SYN_BASE}/tests/browser"

read -r -d '' BODY <<'JSON' || true
{
  "test": {
    "name": "__SYNTHETIC_NAME__",
    "active": true,
    "deviceId": __SYNTHETIC_DEVICE_ID__,
    "frequency": __SYNTHETIC_FREQUENCY__,
    "locationIds": __SYNTHETIC_LOCATIONS__,
    "schedulingStrategy": "round_robin",
    "automaticRetries": 0,
    "urlProtocol": "__URL_PROTOCOL__",
    "startUrl": "__START_NO_PROTO__",
    "transactions": [
      {
        "name": "load SPA login page",
        "steps": [
          {
            "name": "Go to login URL",
            "type": "go_to_url",
            "url": "__SYNTHETIC_BROWSER_URL__",
            "action": "go_to_url",
            "options": {"url": "__SYNTHETIC_BROWSER_URL__"}
          },
          {
            "name": "Assert username field present",
            "type": "assert_element_present",
            "selectorType": "css",
            "selector": "input[name=username]"
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
BODY="${BODY//__SYNTHETIC_BROWSER_URL__/${BR_URL}}"
BODY="${BODY//__SYNTHETIC_DEVICE_ID__/${SYNTHETIC_DEVICE_ID}}"
BODY="${BODY//__URL_PROTOCOL__/${URL_PROTOCOL}}"
BODY="${BODY//__START_NO_PROTO__/${START_NO_PROTO}}"

auth_header=("-H" "X-SF-TOKEN: ${SPLUNK_API_TOKEN}")
content_header=("-H" "Content-Type: application/json")

echo "[synthetic-browser] looking up existing check named '${SYNTHETIC_NAME}'"
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
    if it.get("name") == name and it.get("type") == "browser":
        target = str(it.get("id") or it.get("testId") or "")
        break
print(target)
' 2>/dev/null || true)

if [[ -n "${existing_id}" ]]; then
  echo "[synthetic-browser] updating existing check id=${existing_id}"
  curl -gfsS -X PUT "${API_TESTS_BROWSER}/${existing_id}" \
    "${auth_header[@]}" "${content_header[@]}" \
    --data "${BODY}" >/dev/null
else
  echo "[synthetic-browser] creating new check"
  curl -gfsS -X POST "${API_TESTS_BROWSER}" \
    "${auth_header[@]}" "${content_header[@]}" \
    --data "${BODY}" >/dev/null
fi

echo "[synthetic-browser] done"
