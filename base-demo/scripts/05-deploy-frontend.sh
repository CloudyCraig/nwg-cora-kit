#!/usr/bin/env bash
# Enable + deploy the web-frontend on top of an already-running natwest
# Helm release. Run after scripts/03-deploy.sh because the frontend's
# /api/ proxy assumes the api-gateway Service is up.
#
# Required env vars:
#   SPLUNK_RUM_TOKEN      - Splunk RUM access token (separate from the
#                           collector / APM access token; create one in
#                           Splunk Observability > Settings > Access Tokens)
#   SPLUNK_REALM          - Splunk realm (e.g. us0, us1, eu0)
# Optional env vars:
#   FRONTEND_TAG          - tag for the web-frontend image (defaults to IMAGE_TAG)
#   FRONTEND_GATEWAY_URL  - URL the SPA uses for /process. Defaults to
#                           same-origin "/api" so nginx proxies via the
#                           in-cluster Service. Override with the api-gateway
#                           LoadBalancer URL if you'd prefer a direct
#                           browser->gateway hop.
#   FRONTEND_REPLICAS     - number of replicas (default 1)
#   FRONTEND_SERVICE_TYPE - Service type for web-frontend. Defaults to
#                           LoadBalancer; override to NodePort or ClusterIP
#                           when an AWS Org SCP denies elasticloadbalancing:*
#                           (use scripts/05a-frontend-portforward.sh in that
#                           case to reach the SPA over kubectl port-forward).
#   FRONTEND_OBSERVABILITY_URL
#                         - URL the "Observability" link in the SPA top-nav
#                           opens in a new tab. Defaults to
#                           https://app.${SPLUNK_REALM}.signalfx.com/ so the
#                           operator lands in the same region the RUM agent
#                           reports to. Set to an empty string to hide the
#                           link, or to a deep link such as
#                           https://app.us0.signalfx.com/#/apm/services to
#                           jump straight into APM Service Map.
#   FRONTEND_ITSI_URL     - URL the "ITSI" link opens in a new tab. Defaults
#                           to ${splunk_enterprise_web_url}/en-US/app/itsi
#                           (Episode Review). Set to "" to hide the link or
#                           to a Glass Table deep link to jump straight to
#                           the demo dashboard.
#   FRONTEND_THOUSANDEYES_URL
#                         - URL the "ThousandEyes" link opens in a new tab.
#                           Defaults to https://app.thousandeyes.com/?aid=
#                           ${TE_ACCOUNT_GROUP_ID}#/views/tests when the AID
#                           is set in secrets/thousandeyes.env (sourced by
#                           the block below), or to https://app.thousandeyes
#                           .com/ otherwise. Set to "" to hide the link.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_cmd kubectl helm terraform

: "${SPLUNK_RUM_TOKEN:?SPLUNK_RUM_TOKEN must be set (Splunk Observability RUM access token)}"
: "${SPLUNK_REALM:?SPLUNK_REALM must be set (e.g. us0, eu0)}"

SERVICE_REPO=$(tf_output ecr_service_repo_url)
LEDGER_JAVA_REPO=$(tf_output ecr_ledger_service_java_repo_url)
# Pinned to the pg_sleep build (see 03-deploy.sh / values.yaml). Defaulting to
# IMAGE_TAG reverts the cluster to the pre-pg_sleep ledger build and breaks the
# db-slow demo. Override with LEDGER_JAVA_TAG=<newer> only after rebuilding it.
LEDGER_JAVA_TAG="${LEDGER_JAVA_TAG:-0.1.7}"
# Pinned to the build carrying the outbound HTTP connection-pool fix (see
# 03-deploy.sh). Defaulting to IMAGE_TAG reverts the Python services to the
# pre-fix image whose default urllib3 pool of 10 overflows under fan-out load,
# re-introducing the multi-second baseline that masks injected chaos. Override
# with SERVICE_TAG=<newer> only after rebuilding the Python service image.
SERVICE_TAG="${SERVICE_TAG:-0.1.7}"
FRONTEND_REPO=$(tf_output ecr_web_frontend_repo_url)
FRONTEND_TAG="${FRONTEND_TAG:-${IMAGE_TAG}}"
FRONTEND_GATEWAY_URL="${FRONTEND_GATEWAY_URL:-/api}"
FRONTEND_REPLICAS="${FRONTEND_REPLICAS:-1}"
FRONTEND_SERVICE_TYPE="${FRONTEND_SERVICE_TYPE:-NodePort}"

# --- Cross-launch links into Splunk surfaces -------------------------------
# These power the "Observability" and "ITSI" buttons in the SPA top-nav
# (frontend/src/App.tsx). The chart hides each button when its value is
# empty, so an operator can opt out of either link by setting it to "".
#
#   * FRONTEND_OBSERVABILITY_URL defaults to the realm-aware Splunk
#     Observability home. We avoid a path suffix (#/apm/services etc.)
#     so the user lands wherever their personal preferences last left
#     them; presenters who want a deterministic landing page should
#     override at deploy time.
#   * FRONTEND_ITSI_URL defaults to the Splunk Enterprise Web URL +
#     /en-US/app/itsi (the ITSI app root, which lands on Service
#     Analyzer). Empty when terraform hasn't created the Splunk
#     Enterprise instance yet (var.splunk_enterprise_enabled=false).
#
# The Splunk Enterprise output is best-effort; tf_output is a thin
# wrapper around `terraform output -raw` which returns "" when the
# output is missing or null, so the script never aborts when ITSI
# wasn't deployed.
DEFAULT_OBSERVABILITY_URL="https://app.${SPLUNK_REALM}.signalfx.com/"
SPLUNK_WEB_URL="$(tf_output splunk_enterprise_web_url 2>/dev/null || true)"
if [[ -n "${SPLUNK_WEB_URL}" && "${SPLUNK_WEB_URL}" != "null" ]]; then
  DEFAULT_ITSI_URL="${SPLUNK_WEB_URL%/}/en-US/app/itsi"
else
  DEFAULT_ITSI_URL=""
fi

# ThousandEyes default. secrets/thousandeyes.env is the canonical source
# for TE_ACCOUNT_GROUP_ID (created by scripts/08-configure-thousandeyes.
# sh); sourcing it here makes the cross-launch link land on the right
# tenant on a fresh deploy. We snapshot/restore set -u and -e around the
# `source` because the file may legitimately contain `KEY=` (empty)
# lines and we don't want a missing or empty AID to abort the whole
# deploy. The source is gated on the file existing so chart-only
# tenants without TE configured still deploy cleanly.
TE_ENV_FILE="${REPO_ROOT}/secrets/thousandeyes.env"
if [[ -f "${TE_ENV_FILE}" ]]; then
  set +u
  # shellcheck disable=SC1090
  source "${TE_ENV_FILE}" >/dev/null 2>&1 || true
  set -u
fi
if [[ -n "${TE_ACCOUNT_GROUP_ID:-}" ]]; then
  # `?aid=` lives BEFORE the URL fragment so the TE SPA can read it
  # from window.location.search; placing it after the # would put it
  # in the hash and TE would ignore the scoping. The Views > Tests
  # landing page tells the same story as the demo's synthetic checks.
  DEFAULT_THOUSANDEYES_URL="https://app.thousandeyes.com/?aid=${TE_ACCOUNT_GROUP_ID}#/views/tests"
else
  DEFAULT_THOUSANDEYES_URL="https://app.thousandeyes.com/"
fi

FRONTEND_OBSERVABILITY_URL="${FRONTEND_OBSERVABILITY_URL-${DEFAULT_OBSERVABILITY_URL}}"
FRONTEND_ITSI_URL="${FRONTEND_ITSI_URL-${DEFAULT_ITSI_URL}}"
FRONTEND_THOUSANDEYES_URL="${FRONTEND_THOUSANDEYES_URL-${DEFAULT_THOUSANDEYES_URL}}"

# --- SPA login gate (demo) -------------------------------------------------
# Hash the plaintext locally so we can pass --set frontend.auth.passwordSha256
# without ever persisting the plaintext to a manifest, a values file, or the
# Helm release history. WEB_AUTH_PASSWORD is sourced from .env (see lib.sh)
# or the operator's shell - never from source. WEB_AUTH_ENABLED defaults
# true so the demo always has a login screen; set "false" to disable.
WEB_AUTH_ENABLED="${WEB_AUTH_ENABLED:-true}"
WEB_AUTH_USERNAME="${WEB_AUTH_USERNAME:-admin}"
WEB_AUTH_SET=()
if [[ "${WEB_AUTH_ENABLED}" == "true" ]]; then
  : "${WEB_AUTH_PASSWORD:?WEB_AUTH_PASSWORD must be set when WEB_AUTH_ENABLED=true (put it in .env or export inline)}"
  if command -v shasum >/dev/null 2>&1; then
    WEB_AUTH_PASSWORD_SHA256=$(printf '%s' "${WEB_AUTH_PASSWORD}" | shasum -a 256 | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    WEB_AUTH_PASSWORD_SHA256=$(printf '%s' "${WEB_AUTH_PASSWORD}" | sha256sum | awk '{print $1}')
  else
    fail "neither shasum nor sha256sum is available; install one or set WEB_AUTH_ENABLED=false"
  fi
  WEB_AUTH_SET+=(
    "--set" "frontend.auth.enabled=true"
    "--set" "frontend.auth.username=${WEB_AUTH_USERNAME}"
    "--set" "frontend.auth.passwordSha256=${WEB_AUTH_PASSWORD_SHA256}"
  )
  log "SPA login gate ENABLED (username=${WEB_AUTH_USERNAME}, passwordSha256=${WEB_AUTH_PASSWORD_SHA256:0:8}...)"
else
  WEB_AUTH_SET+=("--set" "frontend.auth.enabled=false")
  log "SPA login gate DISABLED"
fi

log "helm upgrade --install natwest-payments + frontend (frontend=${FRONTEND_REPO}:${FRONTEND_TAG}, gateway=${FRONTEND_GATEWAY_URL}, svcType=${FRONTEND_SERVICE_TYPE})"
log "  cross-launch: observability=${FRONTEND_OBSERVABILITY_URL:-<hidden>} itsi=${FRONTEND_ITSI_URL:-<hidden>} thousandeyes=${FRONTEND_THOUSANDEYES_URL:-<hidden>}"
helm upgrade --install natwest-payments "${HELM_CHART_DIR}" \
  --namespace "${SERVICE_NAMESPACE}" \
  --set image.repository="${SERVICE_REPO}" \
  --set image.tag="${SERVICE_TAG}" \
  --set "services.ledger-service.image.repository=${LEDGER_JAVA_REPO}" \
  --set "services.ledger-service.image.tag=${LEDGER_JAVA_TAG}" \
  --set "frontend.enabled=true" \
  --set "frontend.image.repository=${FRONTEND_REPO}" \
  --set "frontend.image.tag=${FRONTEND_TAG}" \
  --set "frontend.replicas=${FRONTEND_REPLICAS}" \
  --set "frontend.rum.realm=${SPLUNK_REALM}" \
  --set "frontend.rum.accessToken=${SPLUNK_RUM_TOKEN}" \
  --set "frontend.gatewayUrl=${FRONTEND_GATEWAY_URL}" \
  --set "frontend.observabilityUrl=${FRONTEND_OBSERVABILITY_URL}" \
  --set "frontend.itsiUrl=${FRONTEND_ITSI_URL}" \
  --set "frontend.thousandEyesUrl=${FRONTEND_THOUSANDEYES_URL}" \
  --set "frontend.service.type=${FRONTEND_SERVICE_TYPE}" \
  "${WEB_AUTH_SET[@]}" \
  --wait --timeout 10m

# When chaos-controller is enabled, web-frontend must serve the same
# CHAOS_PRESENTER_TOKEN as the controller. secretKeyRef env vars are
# fixed at pod start; a frontend-only helm upgrade leaves stale tokens
# and the /ops dashboard returns 401.
CHAOS_ENABLED="$(helm get values natwest-payments -n "${SERVICE_NAMESPACE}" -o json 2>/dev/null \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("chaosController",{}).get("enabled", False))' 2>/dev/null || echo false)"
if [[ "${CHAOS_ENABLED}" == "True" || "${CHAOS_ENABLED}" == "true" ]]; then
  log "chaos-controller enabled — rolling web-frontend to sync presenter token into /config.js"
  kubectl -n "${SERVICE_NAMESPACE}" rollout restart deploy/web-frontend
  kubectl -n "${SERVICE_NAMESPACE}" rollout status deploy/web-frontend --timeout=180s
fi

if [[ "${FRONTEND_SERVICE_TYPE}" == "LoadBalancer" ]]; then
  log "waiting for LoadBalancer ingress..."
  for i in $(seq 1 60); do
    HOSTNAME=$(kubectl -n "${SERVICE_NAMESPACE}" get svc web-frontend \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    IP=$(kubectl -n "${SERVICE_NAMESPACE}" get svc web-frontend \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [[ -n "${HOSTNAME}" || -n "${IP}" ]]; then
      log "web-frontend reachable at: http://${HOSTNAME:-${IP}}/"
      break
    fi
    sleep 5
    printf '.'
  done
  echo
else
  log "frontend service type is ${FRONTEND_SERVICE_TYPE}; skipping LB wait"
  # Public path: nginx on the Splunk EC2 fronts the NodePort. If the proxy
  # is enabled in terraform, surface the URL directly so the presenter
  # doesn't have to chase a port-forward.
  PUBLIC_SPA_URL="$(terraform -chdir="${TERRAFORM_DIR}" output -raw public_spa_url 2>/dev/null || true)"
  if [[ -n "${PUBLIC_SPA_URL}" && "${PUBLIC_SPA_URL}" != "null" ]]; then
    log "public SPA URL (via Splunk EC2 nginx): ${PUBLIC_SPA_URL}"
    log "if the proxy hasn't been configured yet, run scripts/05b-frontend-public-proxy.sh"
  else
    log "use 'scripts/05a-frontend-portforward.sh' to reach the SPA on http://localhost:8080/"
    log "or enable the public reverse proxy: terraform var.public_spa_proxy_enabled=true + scripts/05b-frontend-public-proxy.sh"
  fi
fi

kubectl -n "${SERVICE_NAMESPACE}" get deploy/web-frontend svc/web-frontend -o wide
