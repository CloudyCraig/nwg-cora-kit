#!/bin/sh
set -e
echo "[cora] installing deps..."
pip install --no-cache-dir -q -r /app/requirements.txt
echo "[cora] starting (model=${CORA_MODEL:-claude-opus-5})..."
exec opentelemetry-instrument gunicorn --chdir /app -b 0.0.0.0:8080 \
  -w 1 --threads 8 -k gthread --timeout 90 app:app
