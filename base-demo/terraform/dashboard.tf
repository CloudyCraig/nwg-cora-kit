# Payments Operations dashboard.
#
# Pivots on the business span attributes already emitted by every span
# (`payment.scheme`, `payment.country_pair`, `customer.tier`,
# `cache.namespace`, `cache.hit`). Single dashboard group with charts
# that line up with the run-of-show: RUM -> APM -> Profiling ->
# Detectors -> Synthetic -> Dashboard.

resource "signalfx_dashboard_group" "payments_ops" {
  count = local.obs_enabled ? 1 : 0

  name        = "[NatWest demo] Payments Operations"
  description = "VP-of-Payments view: throughput, latency, errors and cache health across all payment schemes."

  teams = []
}

resource "signalfx_time_chart" "rps_by_scheme" {
  count = local.obs_enabled ? 1 : 0

  name        = "RPS by payment scheme"
  description = "Requests per second through api-gateway, broken out by payment.scheme."

  program_text = <<-EOF
    A = data('spans.count', filter=filter('sf_service','api-gateway') and filter('sf_environment','demo'), rollup='rate').sum(by=['payment.scheme']).publish(label='RPS')
  EOF

  plot_type         = "AreaChart"
  show_data_markers = false
  legend_options_fields {
    property = "payment.scheme"
    enabled  = true
  }

  unit_prefix = "Metric"
  axis_left {
    label         = "req/s"
    min_value     = 0
    low_watermark = 0
  }
}

resource "signalfx_time_chart" "p99_latency_by_scheme" {
  count = local.obs_enabled ? 1 : 0

  name        = "p99 latency by scheme (ms)"
  description = "p99 latency on payment-initiation-service grouped by payment.scheme. Watch SWIFT during incident demos."

  program_text = <<-EOF
    A = data('spans.duration.ns.p99', filter=filter('sf_service','payment-initiation-service') and filter('sf_environment','demo')).mean(by=['payment.scheme']).publish(label='p99_ns', enable=False)
    B = (A / 1000000).publish(label='p99_ms')
  EOF

  plot_type = "LineChart"
  axis_left {
    label     = "ms"
    min_value = 0
  }
}

resource "signalfx_time_chart" "error_rate_by_country_pair" {
  count = local.obs_enabled ? 1 : 0

  name        = "Error rate by debtor->creditor country"
  description = "Error rate on api-gateway broken out by payment.country_pair. Highlights cross-border failure modes (SWIFT GB->US, etc)."

  program_text = <<-EOF
    errors = data('spans.count', filter=filter('sf_service','api-gateway') and filter('sf_environment','demo') and filter('sf_error','true'), rollup='rate').sum(by=['payment.country_pair']).publish(label='errors', enable=False)
    total  = data('spans.count', filter=filter('sf_service','api-gateway') and filter('sf_environment','demo'), rollup='rate').sum(by=['payment.country_pair']).publish(label='total', enable=False)
    rate   = (errors / total).fill(value=0).publish(label='error_rate')
  EOF

  plot_type = "AreaChart"
  axis_left {
    label     = "error rate"
    min_value = 0
  }
}

resource "signalfx_single_value_chart" "gbp_volume_per_hour" {
  count = local.obs_enabled ? 1 : 0

  name        = "GBP volume processed (last hour)"
  description = "Sum of payment.amount_minor_units / 100 for completed GBP payments through api-gateway in the past hour. Drives the VP-of-Payments narrative ('how much money are we moving?')."

  program_text = <<-EOF
    A = data('spans.payment.amount_minor_units', filter=filter('sf_service','api-gateway') and filter('sf_environment','demo') and filter('payment.currency','GBP') and filter('sf_error','false')).sum().publish(label='minor_units', enable=False)
    B = (A / 100).publish(label='gbp')
  EOF

  unit_prefix         = "Metric"
  is_timestamp_hidden = true
  max_delay           = 60
}

resource "signalfx_time_chart" "cache_hit_ratio" {
  count = local.obs_enabled ? 1 : 0

  name        = "Cache hit ratio by namespace"
  description = "cache.hit=true / total cache lookups, grouped by cache.namespace. Watch the sanctions namespace during the cache-cold incident."

  program_text = <<-EOF
    hits  = data('spans.count', filter=filter('sf_environment','demo') and filter('cache.hit','true'), rollup='rate').sum(by=['cache.namespace']).publish(label='hits', enable=False)
    total = data('spans.count', filter=filter('sf_environment','demo') and filter('cache.namespace','*'), rollup='rate').sum(by=['cache.namespace']).publish(label='total', enable=False)
    ratio = (hits / total).fill(value=0).publish(label='hit_ratio')
  EOF

  plot_type = "LineChart"
  axis_left {
    label     = "hit ratio"
    min_value = 0
    max_value = 1
  }
}

# ---------------------------------------------------------------------------
# Tier-aware charts (Bronze / Silver / Gold).
#
# Powered by the `customer.tier` span attribute that app/service.py and
# LedgerController.java set on every span from the request body. The SPA
# (frontend/src/PersonaContext.tsx) and the load generator
# (traffic-generator/generate.py via TIER_MIX) both emit `customer_tier`
# in the body, so the same dimensions exist on synthetic traffic and
# real-user traffic alike.
# ---------------------------------------------------------------------------
resource "signalfx_time_chart" "p95_latency_by_tier" {
  count = local.obs_enabled ? 1 : 0

  name        = "p95 latency by customer tier (ms)"
  description = "p95 latency on payment-initiation-service grouped by customer.tier. Gold should be visibly faster (tier fast-path) and Bronze the slowest baseline."

  program_text = <<-EOF
    A = data('spans.duration.ns.p95', filter=filter('sf_service','payment-initiation-service') and filter('sf_environment','demo')).mean(by=['customer.tier']).publish(label='p95_ns', enable=False)
    B = (A / 1000000).publish(label='p95_ms')
  EOF

  plot_type = "LineChart"
  axis_left {
    label     = "ms"
    min_value = 0
  }
  legend_options_fields {
    property = "customer.tier"
    enabled  = true
  }
}

resource "signalfx_time_chart" "decline_rate_by_tier" {
  count = local.obs_enabled ? 1 : 0

  name        = "Decline + throttle rate by customer tier"
  description = "(errors + throttled) / total on api-gateway grouped by customer.tier. Bronze should sit near the throttleProb baseline; trips during scripts/incident.sh inject-tier-throttle bronze."

  program_text = <<-EOF
    declines = data('spans.count', filter=filter('sf_service','api-gateway') and filter('sf_environment','demo') and filter('sf_error','true'), rollup='rate').sum(by=['customer.tier']).publish(label='declines', enable=False)
    total    = data('spans.count', filter=filter('sf_service','api-gateway') and filter('sf_environment','demo'), rollup='rate').sum(by=['customer.tier']).publish(label='total', enable=False)
    rate     = (declines / total).fill(value=0).publish(label='decline_rate')
  EOF

  plot_type = "AreaChart"
  axis_left {
    label     = "decline rate"
    min_value = 0
  }
  legend_options_fields {
    property = "customer.tier"
    enabled  = true
  }
}

resource "signalfx_list_chart" "tier_mix" {
  count = local.obs_enabled ? 1 : 0

  name        = "Customer tier mix"
  description = "Live request mix by customer.tier through api-gateway. Should track the TIER_MIX env on the traffic generator (default 60/30/10 Bronze/Silver/Gold) plus whatever the SPA persona switcher is currently using."

  program_text = <<-EOF
    A = data('spans.count', filter=filter('sf_service','api-gateway') and filter('sf_environment','demo'), rollup='rate').sum(by=['customer.tier']).publish(label='tier_mix')
  EOF

  unit_prefix      = "Metric"
  refresh_interval = 30
  max_delay        = 60
  sort_by          = "-value"
  color_by         = "Metric"
}

# ---------------------------------------------------------------------------
# SPA (RUM) charts.
#
# Powered by the new RUM custom events emitted from frontend/src/rum.ts via
# recordPageAction(). Two dimensions matter here:
#   - payment.outcome (MMS) - success / error / timeout, stamped on every
#     payment.completed span by frontend/src/pages/SendMoney.tsx so the
#     funnel is closeable from the customer's POV (not just the gateway's).
#   - network.effective_type (MMS) - 4g / 3g / 2g / slow-2g / wifi, sampled
#     from the Network Information API by frontend/src/rum.ts::initNetworkContext
#     and stamped as a session global so every span carries it.
#
# Both are RUM-only series scoped to sf_service='natwest-payments-web', the
# applicationName the SDK is initialised with (see frontend/src/rum.ts).
# ---------------------------------------------------------------------------
resource "signalfx_time_chart" "spa_payment_outcome_by_tier" {
  count = local.obs_enabled ? 1 : 0

  name        = "SPA payment outcome by customer tier"
  description = "Customer-perceived payment funnel from RUM: payment.completed spans broken out by customer.tier and payment.outcome. The error band on Bronze widens during scripts/incident.sh inject-tier-throttle bronze."

  program_text = <<-EOF
    A = data('spans.count', filter=filter('sf_service','natwest-payments-web') and filter('sf_environment','demo') and filter('payment.outcome','*'), rollup='rate').sum(by=['customer.tier','payment.outcome']).publish(label='spa_outcome')
  EOF

  plot_type = "AreaChart"
  axis_left {
    label     = "events/s"
    min_value = 0
  }
  legend_options_fields {
    property = "customer.tier"
    enabled  = true
  }
  legend_options_fields {
    property = "payment.outcome"
    enabled  = true
  }
}

resource "signalfx_time_chart" "spa_p95_by_network_type" {
  count = local.obs_enabled ? 1 : 0

  name        = "SPA p95 by network.effective_type (ms)"
  description = "p95 client-perceived duration of payment.completed spans on the SPA, grouped by the browser's reported Network Information API effective_type. Cohort-splits the Madrid latency story between fast-broadband Gold users and 3G Bronze users."

  program_text = <<-EOF
    A = data('spans.duration.ns.p95', filter=filter('sf_service','natwest-payments-web') and filter('sf_environment','demo') and filter('sf_operation','payment.completed')).mean(by=['network.effective_type']).publish(label='p95_ns', enable=False)
    B = (A / 1000000).publish(label='p95_ms')
  EOF

  plot_type = "LineChart"
  axis_left {
    label     = "ms"
    min_value = 0
  }
  legend_options_fields {
    property = "network.effective_type"
    enabled  = true
  }
}

resource "signalfx_list_chart" "slowest_traces" {
  count = local.obs_enabled ? 1 : 0

  name        = "Slowest payment-initiation operations"
  description = "Top operations on payment-initiation-service by p99 latency. Click through to APM for the trace."

  program_text = <<-EOF
    A = data('spans.duration.ns.p99', filter=filter('sf_service','payment-initiation-service') and filter('sf_environment','demo')).mean(by=['sf_operation']).publish(label='p99_ns')
  EOF

  unit_prefix      = "Metric"
  refresh_interval = 30
  max_delay        = 60
  sort_by          = "-value"
}

# Bind the charts into the dashboard group.
resource "signalfx_dashboard" "payments_ops" {
  count = local.obs_enabled ? 1 : 0

  name            = "[NatWest demo] Payments Operations"
  description     = "End-to-end ops view of the payments platform. Pivots: scheme, country pair, customer tier, cache namespace."
  dashboard_group = signalfx_dashboard_group.payments_ops[0].id

  time_range = "-1h"

  chart {
    chart_id = signalfx_time_chart.rps_by_scheme[0].id
    width    = 6
    height   = 3
    row      = 0
    column   = 0
  }
  chart {
    chart_id = signalfx_time_chart.p99_latency_by_scheme[0].id
    width    = 6
    height   = 3
    row      = 0
    column   = 6
  }
  chart {
    chart_id = signalfx_time_chart.error_rate_by_country_pair[0].id
    width    = 6
    height   = 3
    row      = 3
    column   = 0
  }
  chart {
    chart_id = signalfx_single_value_chart.gbp_volume_per_hour[0].id
    width    = 3
    height   = 3
    row      = 3
    column   = 6
  }
  chart {
    chart_id = signalfx_time_chart.cache_hit_ratio[0].id
    width    = 3
    height   = 3
    row      = 3
    column   = 9
  }
  chart {
    chart_id = signalfx_list_chart.slowest_traces[0].id
    width    = 12
    height   = 3
    row      = 6
    column   = 0
  }
  # --- Customer-tier row -----------------------------------------------------
  # p95-by-tier and decline-by-tier sit side-by-side so the Bronze story is
  # legible in a single glance; tier-mix list anchors the right edge as a
  # static "who is hitting us right now?" reference.
  chart {
    chart_id = signalfx_time_chart.p95_latency_by_tier[0].id
    width    = 5
    height   = 3
    row      = 9
    column   = 0
  }
  chart {
    chart_id = signalfx_time_chart.decline_rate_by_tier[0].id
    width    = 5
    height   = 3
    row      = 9
    column   = 5
  }
  chart {
    chart_id = signalfx_list_chart.tier_mix[0].id
    width    = 2
    height   = 3
    row      = 9
    column   = 10
  }
  # --- SPA / RUM row ---------------------------------------------------------
  # Customer-perceived view of the payment funnel from the browser RUM SDK.
  # Sits below the tier row so the audience reads the dashboard top-to-bottom
  # as: APM golden signals -> tier impact -> SPA / customer impact.
  chart {
    chart_id = signalfx_time_chart.spa_payment_outcome_by_tier[0].id
    width    = 6
    height   = 3
    row      = 12
    column   = 0
  }
  chart {
    chart_id = signalfx_time_chart.spa_p95_by_network_type[0].id
    width    = 6
    height   = 3
    row      = 12
    column   = 6
  }
}
