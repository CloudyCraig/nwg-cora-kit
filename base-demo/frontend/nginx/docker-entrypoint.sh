#!/bin/sh
# nginx entrypoint that renders runtime config from environment vars.
#
# Required env vars (chart-managed):
#   RUM_REALM, RUM_ACCESS_TOKEN, APP_NAME, DEPLOYMENT_ENVIRONMENT,
#   GATEWAY_URL, KUBERNETES_NAMESPACE.
#
# All variables are exported into the templates via envsubst, then nginx
# is execve'd as PID 1 so signal handling (SIGTERM/SIGQUIT) works
# correctly under Kubernetes.

set -eu

: "${RUM_REALM:=us0}"
: "${RUM_ACCESS_TOKEN:=}"
: "${APP_NAME:=natwest-payments-web}"
: "${DEPLOYMENT_ENVIRONMENT:=demo}"
: "${GATEWAY_URL:=/api}"
: "${KUBERNETES_NAMESPACE:=natwest}"

# CSP connect-src only accepts full origins (scheme://host[:port]), never a
# relative path. When GATEWAY_URL is same-origin (e.g. the default "/api")
# it's already covered by 'self', so we must NOT emit it into connect-src -
# a relative value makes the browser drop the whole source with
# "invalid source: '/api'. It will be ignored." Only a cross-origin gateway
# URL needs listing; derive its origin, else leave the CSP token empty.
case "${GATEWAY_URL}" in
  http://*|https://*)
    CSP_GATEWAY_ORIGIN="$(printf '%s' "${GATEWAY_URL}" | sed -E 's#^(https?://[^/]+).*#\1#')"
    ;;
  *)
    CSP_GATEWAY_ORIGIN=""
    ;;
esac

# --- Chaos dashboard plumbing ---------------------------------------------
# CHAOS_CONTROLLER_HOST / CHAOS_CONTROLLER_PORT are used in the nginx
# /chaos/api/ reverse-proxy block. CHAOS_PRESENTER_TOKEN is rendered into
# /config.js so the SPA can send it on the X-Chaos-Token header. When the
# chaos-controller is disabled the chart leaves these unset and we fall
# back to a stub upstream that just 502s -- the Ops page handles that
# gracefully.
: "${CHAOS_CONTROLLER_HOST:=chaos-controller.natwest.svc.cluster.local}"
: "${CHAOS_CONTROLLER_PORT:=8080}"
: "${CHAOS_PRESENTER_TOKEN:=}"

# Cora AI assistant backend for the /cora/api/ same-origin proxy.
# NOTE: named CORA_BACKEND_* (not CORA_AGENT_*) because Kubernetes injects
# docker-link style CORA_AGENT_PORT=tcp://... vars for the cora-agent
# Service, which would clobber the default with an invalid value.
# Defaults match the cora-agent Service; when the deployment is absent
# the proxy 502s and the SPA widget degrades gracefully.
: "${CORA_BACKEND_HOST:=cora-agent.natwest.svc.cluster.local}"
: "${CORA_BACKEND_PORT:=8080}"

# --- Cross-launch links into Splunk + Cisco surfaces ---------------------
# OBSERVABILITY_URL, ITSI_URL and THOUSANDEYES_URL are rendered verbatim
# into /config.js (no schema validation here - the chart owns the values).
# When unset, the SPA hides the corresponding nav entry rather than
# rendering a broken link. envsubst with the explicit allow-list further
# down treats empty strings as empty; the React side checks
# `if (config.<x>)` before rendering the <a>, so the dead-link case is
# impossible.
: "${OBSERVABILITY_URL:=}"
: "${ITSI_URL:=}"
: "${THOUSANDEYES_URL:=}"

# Resolver for nginx's per-request DNS lookups (needed by the
# /chaos/api/ proxy_pass $variable form). Read the first nameserver
# from /etc/resolv.conf; this is the CoreDNS clusterIP in EKS. Falls
# back to a sane public-style placeholder so a local docker-compose
# without resolv.conf still parses the config.
if [ -z "${NGINX_RESOLVER:-}" ]; then
  NGINX_RESOLVER="$(awk '/^nameserver/ { print $2; exit }' /etc/resolv.conf 2>/dev/null || echo '127.0.0.11')"
fi
: "${NGINX_RESOLVER:=127.0.0.11}"

# --- Auth gate -------------------------------------------------------------
# AUTH_ENABLED is rendered as the JS literal `true` or `false` (no quotes)
# in config.js, hence the explicit lower-casing/normalisation here.
# AUTH_PASSWORD_SHA256 is the hex SHA-256 of the demo password; the
# plaintext never enters this container. AUTH_USERNAME is non-secret.
: "${AUTH_ENABLED:=false}"
case "${AUTH_ENABLED}" in
  true|TRUE|1|yes) AUTH_ENABLED=true ;;
  *)               AUTH_ENABLED=false ;;
esac
: "${AUTH_USERNAME:=}"
: "${AUTH_PASSWORD_SHA256:=}"

# Defensive: if auth is enabled but the hash is missing, log loudly and
# fall back to disabled so the SPA stays reachable rather than locking
# operators out without an explanation. The chart template is the source
# of truth - this is only a runtime safety net.
if [ "${AUTH_ENABLED}" = "true" ] && [ -z "${AUTH_PASSWORD_SHA256}" ]; then
  echo "[entrypoint] AUTH_ENABLED=true but AUTH_PASSWORD_SHA256 is empty; disabling auth" >&2
  AUTH_ENABLED=false
fi

export RUM_REALM RUM_ACCESS_TOKEN APP_NAME DEPLOYMENT_ENVIRONMENT GATEWAY_URL CSP_GATEWAY_ORIGIN KUBERNETES_NAMESPACE
export AUTH_ENABLED AUTH_USERNAME AUTH_PASSWORD_SHA256
export CHAOS_CONTROLLER_HOST CHAOS_CONTROLLER_PORT CHAOS_PRESENTER_TOKEN NGINX_RESOLVER
export CORA_BACKEND_HOST CORA_BACKEND_PORT
export OBSERVABILITY_URL ITSI_URL THOUSANDEYES_URL

# Render templates. envsubst with an explicit allow-list prevents nginx
# variables (like $host, $proxy_add_x_forwarded_for) from being eaten.
NGINX_VARS='${RUM_REALM} ${RUM_ACCESS_TOKEN} ${APP_NAME} ${DEPLOYMENT_ENVIRONMENT} ${GATEWAY_URL} ${CSP_GATEWAY_ORIGIN} ${KUBERNETES_NAMESPACE} ${AUTH_ENABLED} ${AUTH_USERNAME} ${AUTH_PASSWORD_SHA256} ${CHAOS_CONTROLLER_HOST} ${CHAOS_CONTROLLER_PORT} ${CHAOS_PRESENTER_TOKEN} ${NGINX_RESOLVER} ${OBSERVABILITY_URL} ${ITSI_URL} ${THOUSANDEYES_URL} ${CORA_BACKEND_HOST} ${CORA_BACKEND_PORT}'

mkdir -p /var/run/web-frontend

# The log_format directive must be loaded before default.conf which
# references json_main, so we drop it under conf.d with a 00- prefix
# (lexicographic ordering inside http {} context). It contains no
# template variables; cp is enough.
cp /etc/web-frontend/log_format.conf /etc/nginx/conf.d/00-log_format.conf

envsubst "$NGINX_VARS" \
  </etc/web-frontend/default.conf.template \
  >/etc/nginx/conf.d/default.conf

# config.js is served from a writable scratch path so the static asset
# tree at /usr/share/nginx/html stays read-only and identical across
# replicas. nginx maps /config.js to this file via an `alias` directive.
envsubst "$NGINX_VARS" \
  </etc/web-frontend/config.js.template \
  >/var/run/web-frontend/config.js

# Hand off to nginx. exec replaces the shell so PID 1 is nginx.
exec nginx -g 'daemon off;'
