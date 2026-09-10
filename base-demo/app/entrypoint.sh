#!/bin/sh
set -eu

# Run under Splunk's OpenTelemetry Python bootstrap so Flask + requests +
# logging + metrics are auto-instrumented. The collector endpoint, realm,
# access token and service name are all passed via env vars from Helm.

exec opentelemetry-instrument \
  gunicorn \
    --bind "0.0.0.0:${PORT:-8080}" \
    --workers "${GUNICORN_WORKERS:-2}" \
    --threads "${GUNICORN_THREADS:-4}" \
    --access-logfile - \
    --error-logfile - \
    --log-level warning \
    service:app
