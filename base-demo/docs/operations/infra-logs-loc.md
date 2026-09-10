# Infrastructure logs and Log Observer Connect

Postgres, Redis, and Kafka container logs are collected by the Splunk OTel
collector DaemonSet (`filelog` receiver) and routed to Splunk Enterprise
`index=nwpay_infra` by `transform/infra_routing` in `collector/values.yaml`.
Postgres DBM snapshots use the `sqlquery/postgres` receiver and land in the
same index as `sourcetype=postgres:dbm`.

Direct log ingest to Splunk Observability (`splunk_hec/o11y` with
`log_data_enabled: true`) is intentionally disabled on trial tenants. Use
**Log Observer Connect (LOC)** to federate Splunk Enterprise indexes instead.

## Automated LOC wiring

```bash
# Enterprise bootstrap + optional Observability API update
scripts/05f-configure-loc.sh

# Full admin API update (user-level token, NOT the ingest token):
SPLUNK_API_TOKEN=... scripts/05f-configure-loc.sh
```

Integration id for the eu0 demo org: `GhVhuhqAIAA` (`LOC_INTEGRATION_ID` override).

## LOC index allow-list

In Splunk Observability → **Logs** → **Logs connections**, ensure the
Splunk Enterprise connection's index allow-list includes:

| Index | Purpose |
|-------|---------|
| `main` | Trace-correlated application logs (`trace_id` pivot from APM) |
| `splunkrum` | RUM + Splunk Synthetics |
| `nwpay_infra` | Postgres, Redis, Kafka, nginx infrastructure logs |

Re-run or edit the LOC wizard if the integration predates `nwpay_infra`
routing.

## Splunk Enterprise verification

After cluster traffic is flowing (`scripts/04-start-traffic.sh`):

```spl
index=nwpay_infra sourcetype=postgresql earliest=-15m | head 20
index=nwpay_infra sourcetype=redis earliest=-15m | head 20
index=nwpay_infra sourcetype=kafka earliest=-15m | head 20
index=nwpay_infra sourcetype=postgres:dbm earliest=-15m | head 5
```

Slow-query stderr during `db-slow` chaos:

```spl
index=nwpay_infra sourcetype=postgresql "duration:" earliest=-15m
```

Saved searches ship in the `natwest_demo_inputs` app (Splunk Web → **Reports**):

- Infra Logs - Postgres slow statements
- Infra Logs - Kafka ERROR WARN
- Infra Logs - Redis evictions OOM

## Splunk Observability verification

After LOC includes `nwpay_infra`:

1. **Logs Explorer** — search federated `postgresql`, `redis`, `kafka`
   sourcetypes.
2. **APM → Infrastructure** — open `postgres`, `redis`, or `kafka` service
   node → **Logs** tab (requires `service.name` on infra log records from
   `transform/infra_routing`).
3. **Trace pivot** — app logs only (`index=main` + `trace_id`). Infra broker
   logs do not appear on payment traces unless explicit trace correlation is
   added.

## Automated probes

```bash
scripts/lib/itsi_data_probe.sh
scripts/11-verify-logs.sh          # HEC allow-list + infra search-back
```

## Chaos pairing (expected log signals)

| Scenario | Expected log signal |
|----------|---------------------|
| `db-slow` | `postgresql` slow-statement lines + `postgres:dbm` lock/activity rows |
| `postgres-outage` | Postgres connection errors in app logs + broker retry noise |
| `redis-outage` | `redis` / app cache-miss cascade |
| `kafka-outage` | `kafka` controller/broker errors + settlement idle metrics |

## Collector debug (if probes fail)

```bash
kubectl -n splunk-otel logs ds/splunk-otel-collector-agent -c otel-collector | tail
kubectl get pods -n natwest | grep -E 'postgres|redis|kafka'
```

Confirm `transform/infra_routing` is in the `logs` pipeline processor list
(`collector/values.yaml`) and the otel-collector HEC token allow-list includes
`nwpay_infra` (`scripts/00b-update-splunk-config.sh`).
