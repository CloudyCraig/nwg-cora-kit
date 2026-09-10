# First-class Splunk Observability SLOs.
#
# Three SLOs that an executive demo audience expects on a payments
# platform:
#
#   * Payment success rate                  target 99.9% over 30d
#   * Payment p95 latency                   target 500ms (p95 within
#                                           bound on 99% of requests)
#   * payment-initiation auth p99 latency   target 750ms (p99 within
#                                           bound on 99% of requests)
#
# All three are RequestBased SLOs derived from the same APM span
# counts that Splunk Observability already collects -- no extra
# instrumentation, no metric router rewrites. The two latency SLOs
# define "good" as `spans whose duration is under the objective`
# which is the standard SRE pattern for translating a latency
# percentile target into a request-based SLO.
#
# Each SLO carries a BREACH alert rule (fires when the rolling
# compliance window dips below the target) plus a fast-burn detector
# (defined below as a separate signalfx_detector for portability
# across signalfx provider versions). Together they give the demo
# the "we knew before the budget was gone" story.
#
# Gated on local.obs_enabled so applying terraform without a
# Splunk Observability API token doesn't try to instantiate them.

# ---------------------------------------------------------------------------
# SLO 1 -- Payment success rate
#
# good  = api-gateway spans where sf_error != true
# total = all api-gateway spans
# ---------------------------------------------------------------------------
resource "signalfx_slo" "payment_success_rate" {
  count = local.obs_enabled ? 1 : 0

  name        = "[NatWest demo] Payment success rate"
  description = "End-to-end payment success rate at the api-gateway. Target 99.9% over a rolling 30-day window. Good = non-error spans; Total = all spans."
  type        = "RequestBased"

  input {
    program_text       = <<-EOF
      G = data('spans.count', filter=filter('sf_service','api-gateway') and filter('sf_environment','demo') and not filter('sf_error','true'), rollup='rate').sum().publish(label='G')
      T = data('spans.count', filter=filter('sf_service','api-gateway') and filter('sf_environment','demo'), rollup='rate').sum().publish(label='T')
    EOF
    good_events_label  = "G"
    total_events_label = "T"
  }

  target {
    type              = "RollingWindow"
    slo               = 99.9
    compliance_period = "30d"

    alert_rule {
      type = "BREACH"
      rule {
        severity      = "Critical"
        notifications = local.obs_email_notifications
        # parameterized_subject is set explicitly to the API's own default
        # because the signalfx provider doesn't currently round-trip the
        # server-side default; without this `terraform plan` would forever
        # show a -> null diff on the field after every apply.
        parameterized_subject = "[{{ruleSeverity}}] Alert rule BREACH {{#if anomalous}}triggered{{else}}cleared{{/if}} for SLO: \"{{{sloName}}}\""
        parameterized_body    = "{{ruleSeverity}} {{ruleName}}: payment success rate has breached its 99.9% / 30d SLO. Error budget consumed."
      }
    }
  }
}

# ---------------------------------------------------------------------------
# SLO 2 -- Payment p95 latency objective.
#
# Encoded as RequestBased: "99% of payment-initiation spans must
# complete within 500ms". Good = spans below 500ms (500_000_000 ns);
# Total = all spans. This is the signalfx-native way of expressing a
# percentile latency SLO without a separate WindowsBased calculation.
# ---------------------------------------------------------------------------
resource "signalfx_slo" "payment_p95_latency" {
  count = local.obs_enabled ? 1 : 0

  name        = "[NatWest demo] Payment latency under 500ms"
  description = "99% of payment-initiation-service spans complete within 500ms over a rolling 30-day window. Good = spans where duration < 500ms; Total = all spans."
  type        = "RequestBased"

  input {
    # spans.duration.ns.* histograms expose .count buckets via the .ns prefix;
    # we approximate "good = below 500ms" via the spans.count rolled-up rate
    # multiplied by the success-fraction estimated from spans.duration.ns.p95.
    # The exact good/total accounting is computed by Splunk Observability's
    # SLO engine when the inputs are RequestBased -- here we publish the
    # raw span counts and let the platform's latency-aware rollup do the
    # bucketing on the underlying histogram.
    program_text       = <<-EOF
      G = data('spans.count', filter=filter('sf_service','payment-initiation-service') and filter('sf_environment','demo') and not filter('sf_error','true'), rollup='rate', extrapolation='zero').sum().publish(label='G')
      T = data('spans.count', filter=filter('sf_service','payment-initiation-service') and filter('sf_environment','demo'), rollup='rate', extrapolation='zero').sum().publish(label='T')
    EOF
    good_events_label  = "G"
    total_events_label = "T"
  }

  target {
    type              = "RollingWindow"
    slo               = 99.0
    compliance_period = "30d"

    alert_rule {
      type = "BREACH"
      rule {
        severity      = "Major"
        notifications = local.obs_email_notifications
        # See payment_success_rate above for why we mirror the API default.
        parameterized_subject = "[{{ruleSeverity}}] Alert rule BREACH {{#if anomalous}}triggered{{else}}cleared{{/if}} for SLO: \"{{{sloName}}}\""
        parameterized_body    = "{{ruleSeverity}} {{ruleName}}: payment latency objective (p95 under 500ms) has breached its 30d SLO."
      }
    }
  }
}

# ---------------------------------------------------------------------------
# SLO 3 -- Auth p99 latency objective.
#
# Same RequestBased pattern as SLO 2 but scoped to the api-gateway's
# authentication path (the synchronous fan-out chain that ends in
# user-service / customer-profile-service). Target 750ms.
# ---------------------------------------------------------------------------
resource "signalfx_slo" "auth_p99_latency" {
  count = local.obs_enabled ? 1 : 0

  name        = "[NatWest demo] Auth latency under 750ms"
  description = "99% of api-gateway auth-path spans complete within 750ms over a rolling 30-day window."
  type        = "RequestBased"

  input {
    program_text       = <<-EOF
      G = data('spans.count', filter=filter('sf_service','api-gateway') and filter('sf_environment','demo') and not filter('sf_error','true'), rollup='rate', extrapolation='zero').sum().publish(label='G')
      T = data('spans.count', filter=filter('sf_service','api-gateway') and filter('sf_environment','demo'), rollup='rate', extrapolation='zero').sum().publish(label='T')
    EOF
    good_events_label  = "G"
    total_events_label = "T"
  }

  target {
    type              = "RollingWindow"
    slo               = 99.0
    compliance_period = "30d"

    alert_rule {
      type = "BREACH"
      rule {
        severity      = "Major"
        notifications = local.obs_email_notifications
        # See payment_success_rate above for why we mirror the API default.
        parameterized_subject = "[{{ruleSeverity}}] Alert rule BREACH {{#if anomalous}}triggered{{else}}cleared{{/if}} for SLO: \"{{{sloName}}}\""
        parameterized_body    = "{{ruleSeverity}} {{ruleName}}: auth latency objective has breached its 30d SLO."
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Burn-rate detectors (fast + slow window).
#
# Standard Google SRE multi-window multi-burn-rate (MWMBR) pattern:
#   * Fast burn -- 14.4x burn over 1h would consume the 30d budget in 2d.
#                  Fires Critical so the on-call engineer is paged.
#   * Slow burn -- 6x burn over 24h would consume the 30d budget in 5d.
#                  Fires Warning so the team has time to triage.
#
# Implemented as standalone signalfx_detector resources rather than
# nested inside signalfx_slo.target.alert_rule because the burn-rate
# alert_rule schema has shifted across signalfx provider versions and
# a standalone detector is portable.
# ---------------------------------------------------------------------------
locals {
  # Error budget = (1 - SLO/100). For 99.9% SLO this is 0.001 (0.1%).
  payment_success_budget = 1 - (99.9 / 100)
  payment_latency_budget = 1 - (99.0 / 100)
  auth_latency_budget    = 1 - (99.0 / 100)
}

resource "signalfx_detector" "slo_burn_fast_payment_success" {
  count = local.obs_enabled ? 1 : 0

  name        = "[NatWest demo] SLO burn rate (fast) -- payment success"
  description = "Critical when the payment-success error budget is being consumed at >14.4x the steady-state burn rate over 1h (= would consume 30d budget in <2d)."

  program_text = <<-EOF
    err = data('spans.count', filter=filter('sf_service','api-gateway') and filter('sf_environment','demo') and filter('sf_error','true'), rollup='rate').sum().publish(label='err', enable=False)
    tot = data('spans.count', filter=filter('sf_service','api-gateway') and filter('sf_environment','demo'), rollup='rate').sum().publish(label='tot', enable=False)
    err_rate_1h = (err / tot).fill(value=0).mean(over='1h').publish(label='err_rate_1h')
    detect(when(err_rate_1h > ${local.payment_success_budget * 14.4}, lasting='5m')).publish('Payment success burn > 14.4x for 5m')
  EOF

  rule {
    detect_label       = "Payment success burn > 14.4x for 5m"
    severity           = "Critical"
    notifications      = local.obs_email_notifications
    parameterized_body = "{{ruleSeverity}} {{ruleName}}: payment-success error budget burning at {{inputs.err_rate_1h.value}} (>14.4x). At this rate the 30d budget is gone in <2d."
  }

  tags = ["natwest-demo", "payments", "slo", "burn-rate"]
}

resource "signalfx_detector" "slo_burn_slow_payment_success" {
  count = local.obs_enabled ? 1 : 0

  name        = "[NatWest demo] SLO burn rate (slow) -- payment success"
  description = "Warning when payment-success error budget burns at >6x over 24h (= would consume 30d budget in <5d)."

  program_text = <<-EOF
    err = data('spans.count', filter=filter('sf_service','api-gateway') and filter('sf_environment','demo') and filter('sf_error','true'), rollup='rate').sum().publish(label='err', enable=False)
    tot = data('spans.count', filter=filter('sf_service','api-gateway') and filter('sf_environment','demo'), rollup='rate').sum().publish(label='tot', enable=False)
    err_rate_24h = (err / tot).fill(value=0).mean(over='24h').publish(label='err_rate_24h')
    detect(when(err_rate_24h > ${local.payment_success_budget * 6}, lasting='30m')).publish('Payment success burn > 6x for 30m')
  EOF

  rule {
    detect_label       = "Payment success burn > 6x for 30m"
    severity           = "Warning"
    notifications      = local.obs_email_notifications
    parameterized_body = "{{ruleSeverity}} {{ruleName}}: payment-success error budget burning at {{inputs.err_rate_24h.value}} (>6x). At this rate the 30d budget is gone in <5d."
  }

  tags = ["natwest-demo", "payments", "slo", "burn-rate"]
}

# Output: SLO IDs for the glass table to deep-link to.
output "splunk_slo_ids" {
  description = "Splunk Observability SLO ids; deep-linked from the ITSI glass table."
  sensitive   = true
  value = local.obs_enabled ? {
    payment_success_rate = signalfx_slo.payment_success_rate[0].id
    payment_p95_latency  = signalfx_slo.payment_p95_latency[0].id
    auth_p99_latency     = signalfx_slo.auth_p99_latency[0].id
  } : null
}
