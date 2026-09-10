# Promoting span attributes to APM MetricSets

## TL;DR

The Splunk Observability Cloud **Service Map → Breakdown** and **Tag
Spotlight** dropdowns only show span attributes that have been
promoted to **APM MetricSets** (formerly "indexed span tags"). The
demo's business attributes — `customer.tier`, `customer.location`,
`payment.scheme`, `payment.roaming`, etc. — are **on every span
already** (verifiable in any APM trace's Span Attributes panel) but
are invisible to those pivots until you promote them.

Two ways to do it:

| Path | Time | Notes |
| --- | --- | --- |
| **A — UI runbook** (this doc) | ~7 min, one-off | Officially supported. Click 13 times. |
| **B — Best-effort script** | ~30 s | `scripts/05d-promote-metricsets.sh` posts to the undocumented internal endpoint and falls back to printing the runbook on failure. |

The canonical list of 13 MetricSets the demo needs lives in
[`scripts/lib/metricsets.json`](../../scripts/lib/metricsets.json) — that
is the single source of truth. This document and the bootstrap
script both read from it; keep them in sync.

---

## Why an API isn't an option (yet)

As of May 2026:

- The Splunk Observability Cloud public API reference at
  [dev.splunk.com/observability/reference](https://dev.splunk.com/observability/reference/)
  lists endpoints for APM Service Topology and APM Visibility Filters,
  but **not** for APM MetricSets.
- The official Terraform provider
  [`splunk-terraform/signalfx`](https://github.com/splunk-terraform/terraform-provider-signalfx)
  has `signalfx_metric_ruleset` (metric pipeline management — a
  different concept) and `signalfx_apm_service_topology` (read-only),
  but **no MetricSet resource**.
- The Splunk help page
  ["Use and manage Troubleshooting MetricSets"](https://help.splunk.com/en/splunk-observability-cloud/monitor-application-performance/analyze-services-with-span-tags-and-metricsets/learn-about-troubleshooting-metricsets/use-and-manage-troubleshooting-metricsets)
  documents the UI flow only.

### Probed paths on `api.eu0.signalfx.com` (May 13, 2026)

`scripts/05d-promote-metricsets.sh` historically posted to one of three
candidate paths; live probing of this tenant shows none of them is a
management endpoint today:

| Path                                  | Method | Status | Notes |
| ------------------------------------- | ------ | ------ | ----- |
| `/v2/apm/topology/metricset`          | POST   | 400    | Service Map **topology search** endpoint (deserialises into `TopologySearchInput`, requires `timeRange` as a `/`-delimited epoch range). A create-shaped body returns `"timeRange is required"`. |
| `/v2/apm/topology/customMetricset`    | POST   | 400    | Same topology-search controller, scoped to custom MetricSets. Returns `{"data":{"serviceName":"customMetricset","inbound":[],"outbound":[],"services":[]}}` for a valid `timeRange` — no CRUD verbs. |
| `/v2/apm/custom/metricset`            | POST   | 404    | Path retired. |
| `/v2/apm/metricset`                   | POST   | 404    | Path retired. |
| `/v2/apm/troubleshooting-metricset`   | POST   | 404    | Never existed on this tenant. |
| `/v2/apm/monitoring-metricset`        | POST   | 404    | Never existed on this tenant. |
| `/v2/apm/spanTag`                     | GET    | 404    | Never existed on this tenant. |

**Conclusion:** APM MetricSets are strictly UI-managed on this tenant
today. The script now recognises the topology-search 400 signature
(`"timeRange is required"`, `"Invalid delimiter used to split time
range"`, `"TopologySearchInput"`) and bails to this runbook after a
single attempt rather than emitting nine identical stack traces.
Re-run the probe when Splunk announces an APM MetricSets API in the
public reference — that will be the signal to re-enable the script.

---

## What to promote

> One row per MetricSet. **TMS** = Troubleshooting MetricSet (free,
> enables Breakdown / Filter / Tag Spotlight). **MMS** = Monitoring
> MetricSet (generates billable metric time-series; required for any
> detector or dashboard chart keyed by the tag).

| Span tag                  | TMS | MMS | Why it's needed                                                                                  |
| ------------------------- | :-: | :-: | ----------------------------------------------------------------------------------------------- |
| `customer.tier`           | ✅  | ✅  | Bronze / Silver / Gold cohort pivot. Feeds `[NatWest demo] Bronze tier decline rate` detector.   |
| `customer.location`       | ✅  | ✅  | Per-city p95 / RPS pivot. Feeds `[NatWest demo] Madrid p95 latency` detector.                    |
| `customer.country`        | ✅  | —   | Glass-table choropleth (customer-origin by country).                                             |
| `customer.region`         | ✅  | —   | EU-WEST / EU-SOUTH / EU-CENTRAL grouping.                                                        |
| `customer.home_country`   | ✅  | —   | Roaming pivots — accountholder's home country vs origin country.                                 |
| `payment.scheme`          | ✅  | ✅  | FPS / BACS / CHAPS / SEPA / SWIFT / Cheque pivot. Feeds `[NatWest demo] SWIFT error rate` detector. |
| `payment.roaming`         | ✅  | ✅  | Cross-border / domestic split. Feeds the ITSI roaming p95 / error-rate KPIs.                     |
| `channel`                 | ✅  | —   | Mobile / online-banking / branch / bankline / partner-api cohort.                                |
| `fraud.algo`              | ✅  | —   | Surfaces the regressed `pairwise` algorithm in Act I.2 / I.4.                                    |
| `action.name`             | ✅  | —   | Stable name on every recordPageAction span (`Send payment`, `payment.completed`, `persona.switched`, `route.transition`, `payee.selected`, `validation.failed`, `cross_launch.clicked`, `chaos.action.requested`, `network.context`, `error.boundary`). RUM Tag Spotlight pivot for SPA user-action analytics. |
| `payment.outcome`         | ✅  | ✅  | Funnel-bottom dimension on every `payment.completed` span (`success` / `error` / `timeout`). Monitoring MTS powers the live conversion-rate-by-tier chart in Act II.B. |
| `chaos.scenario`          | ✅  | —   | Operator-side click marker on every `chaos.action.requested` span emitted from /ops. Pairs with the server-side `nwpay:chaos` audit event in ITSI so each inject/clear has both a browser-side and a controller-side trail. |
| `network.effective_type`  | ✅  | ✅  | Browser Network Information API value (`4g` / `3g` / `2g` / `slow-2g` / `wifi`). Cohort-splits the Madrid latency story between fast-broadband Gold users and 3G Bronze users. Monitoring MTS feeds the `SPA p95 by network type` chart in the Payments Operations dashboard. |

Total: **13 Troubleshooting MetricSets, 6 of which also need Monitoring**.

> **Quota note.** Splunk Observability Cloud caps Troubleshooting
> MetricSets at ~50–100 per org depending on subscription. Thirteen fits
> comfortably; if you're at the edge of your quota check
> Settings → APM & RUM MetricSets → Custom MetricSets for older
> entries you can retire.

---

## UI runbook

For each row in the table above:

1. Splunk Observability Cloud → bottom-left gear → **Settings** → **APM & RUM MetricSets**.
   On some tenants this lives at **Data Management → APM → MetricSets** instead — same dialog.
2. Top-right → **New MetricSet**.
3. Fill in:
   - **Span tag:** the exact dotted name from the table — case-sensitive (`customer.tier`, not `Customer.Tier`).
   - **Troubleshooting MetricSet:** tick if the **TMS** column is ✅.
   - **Monitoring MetricSet:** tick if the **MMS** column is ✅.
   - **Scope:** leave at default (all services). Narrowing scope is
     useful in shared tenants where the tag is also emitted by an
     unrelated team; for this demo we want it everywhere.
4. **Save.**

Repeat 12 more times. New traces are indexed immediately. Existing
traces backfill in 3–5 minutes.

### Verify

1. APM → **Service Map**, scoped to `environment=demo`.
2. Top-right → **Breakdown** dropdown.
3. The new tags should appear in alphabetical order alongside the
   default `db.system.name`, `Endpoint`, `Environment`, `HTTP Method`,
   `Kind`.
4. Pick `customer.tier` → cohorts split into Bronze / Silver / Gold.

Cross-check Tag Spotlight: APM → **Tag Spotlight** → pick any service
→ the same tags appear in the pivot selector.

### Common gotchas

- **Tag is on the span but doesn't appear after 5 minutes.** Confirm
  the MetricSet scope includes the service you're testing on, and
  that you saved with **Active** status (not Paused). Try a hard
  refresh of the Service Map page.
- **HTTP 400 / "tag already indexed".** A MetricSet for that name
  already exists — usually under a different scope. Edit the existing
  one rather than creating a new one.
- **Monitoring MetricSet billing.** Each MMS creates RED metrics
  (`requests`, `errors`, `duration_ns`) keyed by the tag, multiplied
  by service. Cardinality cost = `services × distinct tag values`.
  For this demo:
    - `customer.tier`: 24 services × 3 values = ~72 MTS — fine.
    - `customer.location`: 24 services × 9 values = ~216 MTS — fine.
    - `payment.scheme`: 24 services × 6 values = ~144 MTS — fine.
    - `payment.roaming`: 24 services × 2 values = ~48 MTS — fine.
    - `payment.outcome`: 1 service (RUM-only, browser app) × 3 values
      (`success` / `error` / `timeout`) = 3 MTS — negligible.
    - `network.effective_type`: 1 service (RUM-only) × 5 values
      (`4g` / `3g` / `2g` / `slow-2g` / `wifi`) = 5 MTS — negligible.
  Total budgeted MMS: <500 MTS for the whole demo. Don't promote
  identifiers (`payment_id`, `trace_id`, `customer.id`) — those would
  blow up cardinality.

---

## Running the best-effort script

```bash
export SPLUNK_REALM=eu0                            # or us0, us1, ...
export SPLUNK_API_TOKEN=$(security find-generic-password -s splunk-api-token -w)
# Optional: dry-run prints the runbook without touching the API
# export METRICSETS_DRY_RUN=1
scripts/05d-promote-metricsets.sh
```

Output you'll see when the internal API works:

```
[12:20:39] promoting span attributes to APM MetricSets (best effort)
[12:20:39] candidate endpoint /v2/apm/topology/metricset responded HTTP 200 - using it for POST.
[12:20:40] customer.tier         OK (HTTP 201)
[12:20:40] customer.location     OK (HTTP 201)
[12:20:40] customer.country      OK (HTTP 201)
[12:20:40] customer.region       OK (HTTP 201)
[12:20:40] customer.home_country OK (HTTP 201)
[12:20:41] payment.scheme        OK (HTTP 201)
[12:20:41] payment.roaming       OK (HTTP 201)
[12:20:41] channel               OK (HTTP 201)
[12:20:41] fraud.algo            OK (HTTP 201)
[12:20:41] summary
[12:20:41]   created / already-existed : 9
[12:20:41]   failed                    : 0
[12:20:41]   skipped (no API path)     : 0
[12:20:41] done. Wait 3-5 minutes for the backfill, then refresh Service Map -> Breakdown.
```

Output you'll see when the internal API has moved (or your tenant
hasn't been migrated to that path yet):

```
[12:20:39] WARN: candidate endpoint /v2/apm/topology/metricset returned 404 - tenant doesn't expose this path.
[12:20:39] WARN: candidate endpoint /v2/apm/custom/metricset returned 404 - tenant doesn't expose this path.
[12:20:39] WARN: candidate endpoint /v2/apm/metricset returned 404 - tenant doesn't expose this path.
[12:20:39] WARN: no internal MetricSet endpoint responded - falling back to manual runbook.

============================================================================
 MANUAL UI RUNBOOK  - run for any MetricSet the API path could not confirm
============================================================================
...
```

Output you'll see when the candidate endpoint **does** respond but
turns out to be the topology-search controller (this is the state
on `api.eu0.signalfx.com` as of May 13, 2026):

```
[10:16:07] promoting span attributes to APM MetricSets (best effort)
[10:16:07] candidate endpoint /v2/apm/topology/metricset responded HTTP 405 - using it for POST.
[10:16:07] WARN: customer.tier    endpoint is a topology-search controller, not a MetricSet management endpoint (Splunk has not exposed a CRUD API in this tenant). Skipping the rest of the list and printing the UI runbook.
[10:16:07] summary
[10:16:07]   created / already-existed : 0
[10:16:07]   failed                    : 0
[10:16:07]   skipped (no API path)     : 9
```

That short-circuit is intentional. There is no payload shape that
will make `/v2/apm/topology/metricset` create a MetricSet — the URL
just happens to share a prefix with the management API the UI used
to call. Use the UI runbook above.

You can pin the endpoint manually if you've reverse-engineered it from
your tenant's Network tab:

```bash
METRICSETS_ENDPOINT=/v2/apm/some-new-path scripts/05d-promote-metricsets.sh
```

---

## Maintenance

- **Adding / removing a MetricSet:** edit
  [`scripts/lib/metricsets.json`](../../scripts/lib/metricsets.json).
  The script and this document both consume it; the script's runbook
  output is generated from the same list.
- **Detectors that depend on a MetricSet:** see
  [`terraform/observability.tf`](../../terraform/observability.tf) —
  the `[NatWest demo] Bronze tier decline rate`,
  `[NatWest demo] SWIFT error rate`, and
  `[NatWest demo] Madrid p95 latency` detectors all reference Monitoring
  MetricSets. If you turn one of these into TMS-only, the matching
  detector will fail to find its `spans.duration.ns.p95` series.
- **Removing the demo from a tenant:** the MetricSets are NOT created
  by `terraform apply` and therefore NOT removed by
  `scripts/99-destroy.sh`. Delete them by hand from the same
  Settings → APM & RUM MetricSets dialog when you tear down the demo.

---

## Where the values come from

If you want to confirm the attribute is being emitted before chasing
UI / API problems:

- **RUM-side** (`customer.tier`, `customer.location`): set in
  [`frontend/src/rum.ts`](../../frontend/src/rum.ts) via
  `SplunkRum.setGlobalAttributes(...)` when the persona changes.
- **RUM-side custom user actions** (`action.name`, `payment.outcome`,
  `chaos.scenario`, `network.effective_type`): emitted by
  `recordPageAction(name, attrs)` in
  [`frontend/src/rum.ts`](../../frontend/src/rum.ts). The helper
  stamps `action.name = name` on every span so the operation name is
  also queryable as a tag, and `initNetworkContext()` (called from
  `main.tsx`) emits a `network.context` event at session start with
  the connection details.
- **Server-side** (all of the above plus `payment.scheme`,
  `payment.roaming`, `fraud.algo`): set in
  [`app/service.py`](../../app/service.py) inside the `/process` and
  downstream handlers via `span.set_attribute(...)`.
- **Traffic-generator** (`customer.*`, `payment.*`,
  `customer.home_country`, `channel`): set in
  [`traffic-generator/generate.py`](../../traffic-generator/generate.py)
  inside `_send` and `_build_payload`.

If a tag is missing from the span, the MetricSet promotion will
succeed but the Breakdown dropdown will show "no data" — the issue is
upstream, not in this runbook.
