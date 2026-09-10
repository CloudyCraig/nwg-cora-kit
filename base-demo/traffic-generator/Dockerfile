# syntax=docker/dockerfile:1.7
FROM python:3.12-slim

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
RUN pip install --no-cache-dir -r requirements.txt \
 && opentelemetry-bootstrap -a install

COPY generate.py ./

USER app

ENV OTEL_SERVICE_NAME=traffic-generator \
    OTEL_METRICS_EXPORTER=otlp \
    OTEL_TRACES_EXPORTER=otlp \
    OTEL_LOGS_EXPORTER=none \
    OTEL_EXPORTER_OTLP_PROTOCOL=grpc

ENTRYPOINT ["/usr/bin/tini", "--", "opentelemetry-instrument", "python", "generate.py"]
