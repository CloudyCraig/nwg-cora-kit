#!/usr/bin/env python3
"""Verify Splunk APM service-map topology invariants via Splunk Enterprise.

The NatWest demo relies on peer.service wiring so Splunk APM draws edges
between services instead of rendering disconnected "floating" islands.
This script runs a handful of cheap SPL checks against index=otel_traces
and exits 0 when the map wiring looks healthy.

Usage:
  python3 scripts/lib/verify_apm_topology.py
  python3 scripts/lib/verify_apm_topology.py --host itsi.splunk-observability.com
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.parse
import urllib.request
from dataclasses import dataclass


@dataclass(frozen=True)
class Check:
    name: str
    spl: str
    min_count: int
    hint: str


CHECKS: tuple[Check, ...] = (
    Check(
        name="traffic-generator -> api-gateway (peer.service)",
        spl=(
            'index=otel_traces sourcetype="otel:traces" earliest=-15m '
            'service.name=traffic-generator kind=SPAN_KIND_CLIENT '
            'attributes.peer.service=api-gateway | stats count'
        ),
        min_count=100,
        hint="Rebuild/restart traffic-generator (scripts/04-start-traffic.sh).",
    ),
    Check(
        name="payment-initiation -> kafka (producer peer.service)",
        spl=(
            'index=otel_traces sourcetype="otel:traces" earliest=-15m '
            'service.name=payment-initiation-service kind=SPAN_KIND_PRODUCER '
            'attributes.peer.service=kafka | stats count'
        ),
        min_count=100,
        hint="Run apm-topology-repair or helm upgrade with kafkaPeerService=kafka.",
    ),
    Check(
        name="settlement-service kafka consumer spans",
        spl=(
            'index=otel_traces sourcetype="otel:traces" earliest=-15m '
            'service.name=settlement-service kind=SPAN_KIND_CONSUMER | stats count'
        ),
        min_count=50,
        hint="Ensure KAFKA_CONSUMER_ENABLED=true on settlement-service.",
    ),
    Check(
        name="ledger-service server spans (Java agent alive)",
        spl=(
            'index=otel_traces sourcetype="otel:traces" earliest=-15m '
            'service.name=ledger-service kind=SPAN_KIND_SERVER | stats count'
        ),
        min_count=100,
        hint="Check OTEL_LOGS_EXPORTER=otlp on ledger-service (not otlp_proto_grpc).",
    ),
    Check(
        name="sanctions-aml -> redis (peer.service)",
        spl=(
            'index=otel_traces sourcetype="otel:traces" earliest=-15m '
            'service.name=sanctions-aml-service kind=SPAN_KIND_CLIENT '
            'attributes.peer.service=redis | stats count'
        ),
        min_count=100,
        hint="Ensure cacheUrl is set and OTEL_INSTRUMENTATION_COMMON_PEER_SERVICE_MAPPING includes redis.",
    ),
    Check(
        name="fraud-detection -> redis (peer.service)",
        spl=(
            'index=otel_traces sourcetype="otel:traces" earliest=-15m '
            'service.name=fraud-detection-service kind=SPAN_KIND_CLIENT '
            'attributes.peer.service=redis | stats count'
        ),
        min_count=100,
        hint="Run apm-topology-repair or helm upgrade with peer-service mapping.",
    ),
    Check(
        name="ledger -> postgres (JDBC peer.service)",
        spl=(
            'index=otel_traces sourcetype="otel:traces" earliest=-15m '
            'service.name=ledger-service kind=SPAN_KIND_CLIENT '
            'attributes.peer.service=postgres | stats count'
        ),
        min_count=100,
        hint="Set OTEL_INSTRUMENTATION_COMMON_PEER_SERVICE_MAPPING on ledger-service.",
    ),
)

NEGATIVE_CHECKS: tuple[Check, ...] = (
    Check(
        name="no infra-heartbeat spans (keeps branded glyphs)",
        spl=(
            'index=otel_traces sourcetype="otel:traces" earliest=-15m '
            'span.name=heartbeat | stats count'
        ),
        min_count=0,
        hint="Disable infrastructure.heartbeat in helm and delete infra-heartbeat CronJob.",
    ),
)


def _splunk_count(host: str, port: int, user: str, password: str, spl: str) -> int:
    body = urllib.parse.urlencode(
        {
            "search": f"search {spl}",
            "output_mode": "json",
            "exec_mode": "oneshot",
        }
    ).encode()
    url = f"https://{host}:{port}/services/search/jobs/export"
    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={"Authorization": _basic_auth(user, password)},
    )
    ctx = urllib.request.ssl._create_unverified_context()  # noqa: SLF001
    with urllib.request.urlopen(req, context=ctx, timeout=120) as resp:
        count = 0
        for raw in resp:
            line = raw.decode().strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            result = row.get("result")
            if not result:
                continue
            val = result.get("count", "0")
            try:
                count = int(float(val))
            except (TypeError, ValueError):
                count = 0
        return count


def _basic_auth(user: str, password: str) -> str:
    import base64

    token = base64.b64encode(f"{user}:{password}".encode()).decode()
    return f"Basic {token}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify APM service-map topology")
    parser.add_argument("--host", default="itsi.splunk-observability.com")
    parser.add_argument("--port", type=int, default=8089)
    parser.add_argument("--user", default="admin")
    parser.add_argument("--password", default="smartway")
    args = parser.parse_args()

    failed = 0
    for check in CHECKS:
        count = _splunk_count(
            args.host, args.port, args.user, args.password, check.spl
        )
        if count >= check.min_count:
            print(f"OK   {check.name}: count={count}")
        else:
            failed += 1
            print(f"FAIL {check.name}: count={count} (need >={check.min_count})")
            print(f"      hint: {check.hint}")

    for check in NEGATIVE_CHECKS:
        count = _splunk_count(
            args.host, args.port, args.user, args.password, check.spl
        )
        if count <= check.min_count:
            print(f"OK   {check.name}: count={count}")
        else:
            failed += 1
            print(f"FAIL {check.name}: count={count} (want <={check.min_count})")
            print(f"      hint: {check.hint}")

    if failed:
        print(f"\n{failed} topology check(s) failed.", file=sys.stderr)
        return 1
    print("\nAll APM topology checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
