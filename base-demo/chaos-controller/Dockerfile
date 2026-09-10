# syntax=docker/dockerfile:1.7
#
# chaos-controller: a small Flask app that performs the kubectl-equivalent
# mutations behind the SPA Chaos Dashboard (/ops). Runs as the only pod
# with RBAC to patch deployments in the natwest namespace; the SPA and
# api-gateway remain unchanged.
FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends tini \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 10001 app \
 && useradd  --system --uid 10001 --gid app --home /app --shell /sbin/nologin app

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY --chmod=0755 app/ ./app/

USER app

ENV PORT=8080 \
    NAMESPACE=natwest

EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys; \
urllib.request.urlopen('http://127.0.0.1:8080/chaos/api/health', timeout=2).read(); \
sys.exit(0)" || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", \
  "gunicorn", \
    "--bind", "0.0.0.0:8080", \
    "--workers", "2", \
    "--threads", "2", \
    "--access-logfile", "-", \
    "--error-logfile", "-", \
    "--log-level", "warning", \
    "app.main:app"]
