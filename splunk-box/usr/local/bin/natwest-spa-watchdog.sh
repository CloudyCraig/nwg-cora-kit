#!/usr/bin/env bash
# Probe nginx /__proxy_health. After two consecutive failures, restart
# nginx so the SPA public URL recovers without operator intervention.
# Designed to be run by systemd; never exits non-zero so the timer doesn't
# fall into the failed state.
set -u
STATE=/var/run/natwest-spa-watchdog.fail-count
THRESHOLD=2

# Curl with strict timeouts. -fS exits non-zero on HTTP >= 400 and prints
# a one-line error message; --max-time 4 caps total wall time so the
# timer's RuntimeMaxSec=15 is never breached.
if curl -fsS -m 4 http://127.0.0.1/__proxy_health >/dev/null 2>&1; then
  : >"${STATE}"
  exit 0
fi

count=0
[[ -s "${STATE}" ]] && count="$(cat "${STATE}" 2>/dev/null || echo 0)"
count=$((count + 1))
printf '%d\n' "${count}" >"${STATE}"

echo "natwest-spa-watchdog: /__proxy_health failed (count=${count}/${THRESHOLD})" >&2

if [[ "${count}" -ge "${THRESHOLD}" ]]; then
  echo "natwest-spa-watchdog: threshold reached, restarting nginx" >&2
  systemctl restart nginx || true
  : >"${STATE}"
fi
exit 0
