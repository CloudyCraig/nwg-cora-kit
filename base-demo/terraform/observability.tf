# Splunk Observability config for the NatWest payments demo.
#
# All resources are gated on `var.splunk_observability_enabled` so the
# infrastructure layer (EKS, ECR, secrets) can be provisioned before a
# Splunk API token is available. Once the API token is in place, set
# the variable to true and re-apply.
#
# The data plane is driven by the OTel auto-instrumented services in
# helm/natwest-payments. Span attributes referenced below
# (`payment.scheme`, `payment.country_pair`, `cache.namespace`,
# `cache.hit`) are emitted by `app/service.py` on every span.

locals {
  obs_enabled = var.splunk_observability_enabled && length(var.splunk_api_token) > 0
}

# ---------------------------------------------------------------------------
# Detector 1 - SWIFT error rate at the gateway.
#
# When error rate on api-gateway spans tagged payment.scheme=SWIFT
# exceeds 5% over a 3-minute window we page critical. This is the
# scenario that scripts/incident.sh swift-counterparty-flap simulates.
# ---------------------------------------------------------------------------
resource "signalfx_detector" "swift_error_rate" {
  count = local.obs_enabled ? 1 : 0

  name        = "[NatWest demo] SWIFT error rate"
  description = "Critical when SWIFT-scheme requests through api-gateway exceed 5% error rate for 3 minutes. Driven by traffic-generator + scripts/incident.sh swift-counterparty-flap."

  program_text = <<-EOF
    A = data('spans.count', filter=filter('sf_service','api-gateway') and filter('sf_environment','demo') and filter('payment.scheme','SWIFT') and filter('sf_error','true'), rollup='rate').sum().publish(label='errors', enable=False)
    B = data('spans.count', filter=filter('sf_service','api-gateway') and filter('sf_environment','demo') and filter('payment.scheme','SWIFT'), rollup='rate').sum().publish(label='total', enable=False)
    C = (A / B).fill(value=0).publish(label='error_rate')
    detect(when(C > 0.05, lasting='3m')).publish('SWIFT error rate > 5% for 3m')
    detect(when(C > 0.02, lasting='5m') and not when(C > 0.05, lasting='3m')).publish('SWIFT error rate > 2% for 5m')
  EOF

  rule {
    detect_label       = "SWIFT error rate > 5% for 3m"
    severity           = "Critical"
    notifications      = local.obs_email_notifications
    parameterized_body = "{{ruleSeverity}} {{ruleName}}: SWIFT error rate is {{inputs.C.value}} (>5%) - check fraud-detection-service and swift-network spans in Splunk APM."
  }

  rule {
    detect_label       = "SWIFT error rate > 2% for 5m"
    severity           = "Warning"
    notifications      = local.obs_email_notifications
    parameterized_body = "{{ruleSeverity}} {{ruleName}}: SWIFT error rate is {{inputs.C.value}}; trending toward critical."
  }

  tags = ["natwest-demo", "payments", "swift"]
}

# ---------------------------------------------------------------------------
# Detector 2 - payment-initiation-service p99 latency objective.
#
# Warning when p99 of /process exceeds 1500ms over a 2-minute window.
# Targets the chain pathology: when sanctions-aml or fraud-detection
# stack tail-latency, this is the customer-facing metric that breaches.
#
# Note: this is a fast threshold detector ("latency objective"), not a
# productized SLO with a compliance window. The first-class
# `signalfx_slo` resources defined in observability_slos.tf are the
# real burn-rate-driven SLOs that the executive deck refers to.
# ---------------------------------------------------------------------------
resource "signalfx_detector" "payment_init_p99_latency" {
  count = local.obs_enabled ? 1 : 0

  name        = "[NatWest demo] payment-initiation p99 latency objective"
  description = "Warns when p99 latency on payment-initiation-service exceeds 1500ms for 2 minutes. Fast threshold detector (latency objective). For the windowed SLO with burn-rate alerting see signalfx_slo.payment_p95_latency."

  program_text = <<-EOF
    A = data('spans.duration.ns.p99', filter=filter('sf_service','payment-initiation-service') and filter('sf_environment','demo')).publish(label='p99_ns')
    B = (A / 1000000).publish(label='p99_ms')
    detect(when(B > 1500, lasting='2m')).publish('payment-init p99 > 1500ms for 2m')
    detect(when(B > 3000, lasting='1m')).publish('payment-init p99 > 3000ms for 1m')
  EOF

  rule {
    detect_label       = "payment-init p99 > 3000ms for 1m"
    severity           = "Critical"
    notifications      = local.obs_email_notifications
    parameterized_body = "{{ruleSeverity}} {{ruleName}}: payment-initiation p99 is {{inputs.B.value}}ms. Investigate sanctions-aml-service and fraud-detection-service tail latency."
  }

  rule {
    detect_label       = "payment-init p99 > 1500ms for 2m"
    severity           = "Warning"
    notifications      = local.obs_email_notifications
    parameterized_body = "{{ruleSeverity}} {{ruleName}}: payment-initiation p99 is {{inputs.B.value}}ms (objective 1500ms)."
  }

  tags = ["natwest-demo", "payments", "latency-objective"]
}

# ---------------------------------------------------------------------------
# Detector 3 - Redis cache miss rate (sanctions namespace).
#
# Computed from the cache.hit span attribute. Warns when miss rate goes
# above 10% for 5 minutes - the visible signal of scripts/incident.sh
# cache-cold.
# ---------------------------------------------------------------------------
resource "signalfx_detector" "sanctions_cache_miss_rate" {
  count = local.obs_enabled ? 1 : 0

  name        = "[NatWest demo] sanctions cache miss rate"
  description = "Warns when sanctions-aml-service cache miss rate exceeds 10% for 5 minutes. Driven by scripts/incident.sh cache-cold."

  program_text = <<-EOF
    misses = data('spans.count', filter=filter('sf_service','sanctions-aml-service') and filter('cache.namespace','sanctions') and filter('cache.hit','false'), rollup='rate').sum().publish(label='misses', enable=False)
    total  = data('spans.count', filter=filter('sf_service','sanctions-aml-service') and filter('cache.namespace','sanctions'), rollup='rate').sum().publish(label='total', enable=False)
    miss_rate = (misses / total).fill(value=0).publish(label='miss_rate')
    detect(when(miss_rate > 0.1, lasting='5m')).publish('sanctions cache miss rate > 10% for 5m')
  EOF

  rule {
    detect_label       = "sanctions cache miss rate > 10% for 5m"
    severity           = "Warning"
    notifications      = local.obs_email_notifications
    parameterized_body = "{{ruleSeverity}} {{ruleName}}: sanctions cache miss rate is {{inputs.miss_rate.value}}. Cache may be cold (was scripts/incident.sh cache-cold run?)."
  }

  tags = ["natwest-demo", "payments", "cache"]
}

# ---------------------------------------------------------------------------
# Detector 4 - Bronze tier decline rate at the gateway.
#
# Customer-tier story: when the bank starts throttling the Bronze tier
# (scripts/incident.sh inject-tier-throttle bronze) the decline rate for
# Bronze customers spikes well above the ~3% baseline. Fires Critical at
# 8% sustained for 3m, Warning at 5% for 5m. Silver / Gold should NOT
# trip this because their throttleProb is 0 by default.
# ---------------------------------------------------------------------------
resource "signalfx_detector" "bronze_decline_rate" {
  count = local.obs_enabled ? 1 : 0

  name        = "[NatWest demo] Bronze tier decline rate"
  description = "Critical when Bronze customer.tier requests through api-gateway exceed 8% decline (errors + throttles) for 3 minutes. Driven by scripts/incident.sh inject-tier-throttle bronze."

  program_text = <<-EOF
    declines = data('spans.count', filter=filter('sf_service','api-gateway') and filter('sf_environment','demo') and filter('customer.tier','bronze') and filter('sf_error','true'), rollup='rate').sum().publish(label='declines', enable=False)
    total    = data('spans.count', filter=filter('sf_service','api-gateway') and filter('sf_environment','demo') and filter('customer.tier','bronze'), rollup='rate').sum().publish(label='total', enable=False)
    rate     = (declines / total).fill(value=0).publish(label='bronze_decline_rate')
    detect(when(rate > 0.08, lasting='3m')).publish('Bronze decline rate > 8% for 3m')
    detect(when(rate > 0.05, lasting='5m') and not when(rate > 0.08, lasting='3m')).publish('Bronze decline rate > 5% for 5m')
  EOF

  rule {
    detect_label       = "Bronze decline rate > 8% for 3m"
    severity           = "Critical"
    notifications      = local.obs_email_notifications
    parameterized_body = "{{ruleSeverity}} {{ruleName}}: Bronze decline rate is {{inputs.rate.value}} (>8%) - check api-gateway logs and TIER_THROTTLE_PROB env. Was scripts/incident.sh inject-tier-throttle bronze run?"
  }

  rule {
    detect_label       = "Bronze decline rate > 5% for 5m"
    severity           = "Warning"
    notifications      = local.obs_email_notifications
    parameterized_body = "{{ruleSeverity}} {{ruleName}}: Bronze decline rate is {{inputs.rate.value}}; trending toward critical."
  }

  tags = ["natwest-demo", "payments", "tier"]
}

# ---------------------------------------------------------------------------
# Detector 5 - Madrid customer-side latency.
#
# Splits api-gateway p95 latency by customer.location so a regional
# network-degradation story (e.g. "the Spanish link is slow") shows up
# as a single detector firing on Madrid rather than a noisy global
# p95 lift. The baseline Madrid RTT baked into the traffic generator
# is ~450 ms; the chaos scenario `madrid-network-degradation` bumps
# this to ~2 s. Thresholds are tuned so the baseline sits inside the
# warning band but the chaos scenario trips critical within one
# minute, while the other (sub-200ms) cities never trip.
# ---------------------------------------------------------------------------
resource "signalfx_detector" "madrid_p95_latency" {
  count = local.obs_enabled ? 1 : 0

  name        = "[NatWest demo] Madrid p95 latency"
  description = "Critical when api-gateway p95 latency for customer.location=madrid exceeds 1500ms for 3 minutes. Driven by traffic-generator's baked-in Madrid baseline (~450 ms RTT) escalated via the madrid-network-degradation chaos scenario."

  program_text = <<-EOF
    A = data('spans.duration.ns.p95', filter=filter('sf_service','api-gateway') and filter('sf_environment','demo') and filter('customer.location','madrid')).publish(label='p95_ns')
    B = (A / 1000000).publish(label='madrid_p95_ms')
    detect(when(B > 1500, lasting='3m')).publish('Madrid p95 > 1500ms for 3m')
    detect(when(B > 800, lasting='5m') and not when(B > 1500, lasting='3m')).publish('Madrid p95 > 800ms for 5m')
  EOF

  rule {
    detect_label       = "Madrid p95 > 1500ms for 3m"
    severity           = "Critical"
    notifications      = local.obs_email_notifications
    parameterized_body = "{{ruleSeverity}} {{ruleName}}: Madrid p95 is {{inputs.B.value}}ms. Check traffic-generator LOCATION_LATENCY_PROFILES env (madrid-network-degradation chaos scenario) before chasing a real Spanish-link outage."
  }

  rule {
    detect_label       = "Madrid p95 > 800ms for 5m"
    severity           = "Warning"
    notifications      = local.obs_email_notifications
    parameterized_body = "{{ruleSeverity}} {{ruleName}}: Madrid p95 is {{inputs.B.value}}ms (baseline ~450ms). Investigate per-region network conditions."
  }

  tags = ["natwest-demo", "payments", "location", "madrid"]
}

# ---------------------------------------------------------------------------
# Detector 6 - Bronze SPA failure rate (RUM-side, customer-perceived).
#
# Companion to detector 4 (Bronze decline rate at the gateway). Detector 4
# reads `sf_error=true` on api-gateway server spans, which is what the
# *gateway* says happened. This detector reads the new `payment.outcome`
# attribute on RUM spans emitted by frontend/src/pages/SendMoney.tsx
# `recordPageAction("payment.completed", ...)`, which is what the
# *customer* experienced - including failures the gateway never saw
# (transport errors, request blocked by an ad-blocker, ingress 502, etc).
#
# Fires Critical when Bronze SPA failure rate > 10% for 3m, Warning at
# 5% for 5m. The dimensions are RUM-promoted MetricSets:
#   - customer.tier (MMS) - already promoted, used by detector 4 too
#   - payment.outcome (MMS) - new in this detector batch
#   - sf_service auto-set by the RUM SDK to applicationName, which is
#     "natwest-payments-web" (see frontend/src/rum.ts::initRum config).
# ---------------------------------------------------------------------------
resource "signalfx_detector" "bronze_spa_failure_rate" {
  count = local.obs_enabled ? 1 : 0

  name        = "[NatWest demo] Bronze SPA failure rate"
  description = "Critical when SPA-perceived payment failure rate for Bronze customer.tier exceeds 10% for 3 minutes. Reads the payment.outcome RUM attribute from frontend/src/pages/SendMoney.tsx; fires for transport / ingress / 5xx failures the api-gateway-side detector cannot see."

  program_text = <<-EOF
    failures  = data('spans.count', filter=filter('sf_service','natwest-payments-web') and filter('sf_environment','demo') and filter('customer.tier','bronze') and filter('payment.outcome','error'), rollup='rate').sum().publish(label='failures', enable=False)
    successes = data('spans.count', filter=filter('sf_service','natwest-payments-web') and filter('sf_environment','demo') and filter('customer.tier','bronze') and filter('payment.outcome','success'), rollup='rate').sum().publish(label='successes', enable=False)
    total     = (failures + successes).publish(label='total', enable=False)
    rate      = (failures / total).fill(value=0).publish(label='bronze_spa_failure_rate')
    detect(when(rate > 0.10, lasting='3m')).publish('Bronze SPA failure rate > 10% for 3m')
    detect(when(rate > 0.05, lasting='5m') and not when(rate > 0.10, lasting='3m')).publish('Bronze SPA failure rate > 5% for 5m')
  EOF

  rule {
    detect_label       = "Bronze SPA failure rate > 10% for 3m"
    severity           = "Critical"
    notifications      = local.obs_email_notifications
    parameterized_body = "{{ruleSeverity}} {{ruleName}}: Bronze SPA failure rate is {{inputs.rate.value}} (>10%) - check Splunk RUM for the failing payment.completed spans (filter customer.tier=bronze, payment.outcome=error). Was inject-tier-throttle bronze run, or is the api-gateway ingress unhealthy?"
  }

  rule {
    detect_label       = "Bronze SPA failure rate > 5% for 5m"
    severity           = "Warning"
    notifications      = local.obs_email_notifications
    parameterized_body = "{{ruleSeverity}} {{ruleName}}: Bronze SPA failure rate is {{inputs.rate.value}}; trending toward critical. Cross-check the Bronze tier decline rate detector (gateway-side)."
  }

  tags = ["natwest-demo", "payments", "tier", "rum", "spa"]
}

# Notifications applied to every detector when configured. Email recipients
# come from var.splunk_alert_recipients; the ITSI alert-bridge webhook
# (defined in itsi_alert_bridge.tf) is appended automatically when the
# bridge is enabled. When both lists are empty alerts still fire in the
# Splunk UI but trigger no external action.
locals {
  obs_email_notifications = concat(
    [for addr in var.splunk_alert_recipients : "Email,${addr}"],
    local.obs_itsi_webhook_notifications,
    # Microsoft Teams webhook is opt-in via TF_VAR_microsoft_teams_*
    # (see teams_alert_bridge.tf). The local is `[]` when disabled so
    # concat is a no-op in the default demo build.
    local.obs_teams_webhook_notifications,
  )
}

# ---------------------------------------------------------------------------
# Splunk Synthetics tests (payments API + SPA /healthz API + SPA browser).
#
# Splunk Synthetics is not yet exposed via the splunk-terraform/signalfx
# provider, so we wrap the v2 REST API via local-exec scripts. Each test
# is gated on var.splunk_synthetics_enabled and short-circuits when its URL
# is empty so operators can roll out checks incrementally.
#
# Tests carry tags including "natwest-demo" so they appear in the
# kbs_synthetic_success base search in itsi/service-tree.yaml (DCE KPIs).
# ---------------------------------------------------------------------------
locals {
  synthetics_enabled = local.obs_enabled && var.splunk_synthetics_enabled
}

resource "null_resource" "splunk_synthetic_api_check" {
  count = local.synthetics_enabled && length(var.splunk_synthetic_target_url) > 0 ? 1 : 0

  triggers = {
    realm      = var.splunk_realm
    target     = var.splunk_synthetic_target_url
    locations  = var.splunk_synthetic_locations
    script_sha = filesha256("${path.module}/../scripts/lib/synthetic_check.sh")
  }

  provisioner "local-exec" {
    environment = {
      SPLUNK_REALM         = var.splunk_realm
      SPLUNK_API_TOKEN     = var.splunk_api_token
      SYNTHETIC_TARGET_URL = var.splunk_synthetic_target_url
      SYNTHETIC_NAME       = "[NatWest demo] payments gateway"
      SYNTHETIC_LOCATIONS  = var.splunk_synthetic_locations
    }
    command = "${path.module}/../scripts/lib/synthetic_check.sh"
  }
}

resource "null_resource" "splunk_synthetic_browser_check" {
  count = local.synthetics_enabled && length(var.splunk_synthetic_browser_url) > 0 ? 1 : 0

  triggers = {
    realm      = var.splunk_realm
    target     = var.splunk_synthetic_browser_url
    locations  = var.splunk_synthetic_locations
    script_sha = filesha256("${path.module}/../scripts/lib/synthetic_browser_check.sh")
  }

  provisioner "local-exec" {
    environment = {
      SPLUNK_REALM          = var.splunk_realm
      SPLUNK_API_TOKEN      = var.splunk_api_token
      SYNTHETIC_BROWSER_URL = var.splunk_synthetic_browser_url
      SYNTHETIC_NAME        = "[NatWest demo] payments SPA"
      SYNTHETIC_LOCATIONS   = var.splunk_synthetic_locations
    }
    command = "${path.module}/../scripts/lib/synthetic_browser_check.sh"
  }
}

resource "null_resource" "splunk_synthetic_spa_health_check" {
  count = local.synthetics_enabled && length(var.splunk_synthetic_spa_health_url) > 0 ? 1 : 0

  triggers = {
    realm      = var.splunk_realm
    target     = var.splunk_synthetic_spa_health_url
    locations  = var.splunk_synthetic_locations
    script_sha = filesha256("${path.module}/../scripts/lib/synthetic_spa_health_check.sh")
  }

  provisioner "local-exec" {
    environment = {
      SPLUNK_REALM             = var.splunk_realm
      SPLUNK_API_TOKEN         = var.splunk_api_token
      SYNTHETIC_SPA_HEALTH_URL = var.splunk_synthetic_spa_health_url
      SYNTHETIC_NAME           = "[NatWest demo] SPA health"
      SYNTHETIC_LOCATIONS      = var.splunk_synthetic_locations
    }
    command = "${path.module}/../scripts/lib/synthetic_spa_health_check.sh"
  }
}

# ---------------------------------------------------------------------------
# Public-proxy watchdog (external).
#
# Probes /__proxy_health on the nginx reverse proxy installed by
# scripts/05b-frontend-public-proxy.sh. The endpoint is served *inside*
# nginx (it does not proxy to the upstream), so:
#
#   * green here = nginx is up and the EIP / DNS / SG path is open
#   * red here   = the proxy box is unreachable from the public internet
#
# The systemd watchdog installed alongside nginx (same script) recovers
# fast local failures within seconds. This synthetic is the *external*
# watchdog: it pages the operator when the watchdog itself can't help
# (instance stopped, EIP detached, AZ outage, route53 broken).
#
# Reuses synthetic_spa_health_check.sh because the contract is identical
# (HTTP 200, body contains "ok"). Only the test name and URL differ.
# ---------------------------------------------------------------------------
resource "null_resource" "splunk_synthetic_proxy_health_check" {
  count = local.synthetics_enabled && length(var.splunk_synthetic_proxy_health_url) > 0 ? 1 : 0

  triggers = {
    realm      = var.splunk_realm
    target     = var.splunk_synthetic_proxy_health_url
    locations  = var.splunk_synthetic_locations
    script_sha = filesha256("${path.module}/../scripts/lib/synthetic_spa_health_check.sh")
  }

  provisioner "local-exec" {
    environment = {
      SPLUNK_REALM             = var.splunk_realm
      SPLUNK_API_TOKEN         = var.splunk_api_token
      SYNTHETIC_SPA_HEALTH_URL = var.splunk_synthetic_proxy_health_url
      SYNTHETIC_NAME           = "[NatWest demo] public proxy health"
      SYNTHETIC_LOCATIONS      = var.splunk_synthetic_locations
    }
    command = "${path.module}/../scripts/lib/synthetic_spa_health_check.sh"
  }
}

# ===========================================================================
# Infrastructure detectors (Redis, Postgres, Kafka)
#
# Powered by metrics emitted from the in-cluster collector via:
#   * native receivers: redis, postgresql, kafkametrics  (collector/values.yaml)
#   * prometheus/infra scraper of redis_exporter / postgres_exporter / jmx_exporter
# All metric names below are the OTel/SignalFx-schema names that land in
# Splunk Observability after collector forwarding. Metric availability can
# be verified manually with:
#   curl -s -H "X-SF-TOKEN: $TOKEN" \
#     "https://api.<realm>.signalfx.com/v2/metric?query=redis.*"
# ===========================================================================

# ---------------------------------------------------------------------------
# Detector 5 - Redis evicted keys (memory pressure / cache thrash).
#
# Fires Major when redis_exporter reports more than 100 evictions per minute
# sustained for 3 minutes - the cache is too small or churning. Tied to the
# scripts/incident.sh cache-cold scenario which forces frequent misses.
# ---------------------------------------------------------------------------
resource "signalfx_detector" "infra_redis_evictions" {
  count = local.obs_enabled ? 1 : 0

  name        = "[NatWest demo] Redis evicted keys"
  description = "Major when Redis evictions exceed 100/min for 3 minutes. Suggests cache thrashing or undersized maxmemory."

  # redis.keys.evicted is a cumulative counter; rate() turns it into per-second
  # then we multiply by 60 to land on per-minute, the units the threshold is
  # expressed in. The metric is published once per scrape interval (30s).
  program_text = <<-EOF
    A = data('redis.keys.evicted').rateofchange().scale(60).publish(label='evictions_per_min')
    detect(when(A > 100, lasting='3m')).publish('Redis evictions > 100/min for 3m')
  EOF

  rule {
    detect_label       = "Redis evictions > 100/min for 3m"
    severity           = "Major"
    notifications      = local.obs_email_notifications
    parameterized_body = "{{ruleSeverity}} {{ruleName}}: Redis is evicting {{inputs.A.value}} keys/min. Check sanctions / fraud cache hit rates and consider raising maxmemory."
  }

  tags = ["natwest-demo", "infra", "redis"]
}

# ---------------------------------------------------------------------------
# Detector 6 - Redis memory utilisation.
#
# Critical when used / max > 0.9. Uses redis_exporter's
# redis_memory_used_bytes and redis_memory_max_bytes (both gauges).
# ---------------------------------------------------------------------------
resource "signalfx_detector" "infra_redis_memory" {
  count = local.obs_enabled ? 1 : 0

  name        = "[NatWest demo] Redis memory utilisation"
  description = "Critical when Redis used memory exceeds 90% of maxmemory for 2 minutes."

  program_text = <<-EOF
    used = data('redis_memory_used_bytes').publish(label='used', enable=False)
    cap  = data('redis_memory_max_bytes').publish(label='max', enable=False)
    util = (used / cap).publish(label='memory_utilisation')
    detect(when(util > 0.9, lasting='2m')).publish('Redis memory > 90% for 2m')
    detect(when(util > 0.75, lasting='5m') and not when(util > 0.9, lasting='2m')).publish('Redis memory > 75% for 5m')
  EOF

  rule {
    detect_label       = "Redis memory > 90% for 2m"
    severity           = "Critical"
    notifications      = local.obs_email_notifications
    parameterized_body = "{{ruleSeverity}} {{ruleName}}: Redis memory utilisation is {{inputs.util.value}} (>90%). Evictions likely; cache effectiveness will degrade."
  }

  rule {
    detect_label       = "Redis memory > 75% for 5m"
    severity           = "Warning"
    notifications      = local.obs_email_notifications
    parameterized_body = "{{ruleSeverity}} {{ruleName}}: Redis memory utilisation is {{inputs.util.value}}; trending toward critical."
  }

  tags = ["natwest-demo", "infra", "redis"]
}

# ---------------------------------------------------------------------------
# Detector 7 - Postgres connections saturation.
#
# Fires High when active backends / max_connections > 0.85 for 2 minutes.
# Uses pg_stat_database backend count vs the postgresql.connection.max
# setting (both surfaced by postgres_exporter).
# ---------------------------------------------------------------------------
resource "signalfx_detector" "infra_postgres_connections" {
  count = local.obs_enabled ? 1 : 0

  name        = "[NatWest demo] Postgres connection saturation"
  description = "High when active Postgres backends exceed 85% of max_connections for 2 minutes."

  program_text = <<-EOF
    active = data('pg_stat_database_numbackends').sum().publish(label='active', enable=False)
    cap    = data('pg_settings_max_connections').publish(label='max', enable=False)
    util   = (active / cap).publish(label='connection_utilisation')
    detect(when(util > 0.85, lasting='2m')).publish('Postgres connections > 85% for 2m')
  EOF

  rule {
    detect_label       = "Postgres connections > 85% for 2m"
    severity           = "Major"
    notifications      = local.obs_email_notifications
    parameterized_body = "{{ruleSeverity}} {{ruleName}}: Postgres connection utilisation is {{inputs.util.value}}. ledger-service connection pool may be saturating."
  }

  tags = ["natwest-demo", "infra", "postgres"]
}

# ---------------------------------------------------------------------------
# Detector 8 - Postgres deadlocks.
#
# Fires Major on any deadlock - they are pathological in this demo (no
# concurrent writers should be racing). Uses pg_stat_database deadlocks
# counter with rate-of-change.
# ---------------------------------------------------------------------------
resource "signalfx_detector" "infra_postgres_deadlocks" {
  count = local.obs_enabled ? 1 : 0

  name        = "[NatWest demo] Postgres deadlocks"
  description = "Major on any Postgres deadlock detected within the last minute."

  program_text = <<-EOF
    A = data('pg_stat_database_deadlocks').sum().rateofchange().scale(60).publish(label='deadlocks_per_min')
    detect(when(A > 0, lasting='1m')).publish('Postgres deadlocks detected')
  EOF

  rule {
    detect_label       = "Postgres deadlocks detected"
    severity           = "Major"
    notifications      = local.obs_email_notifications
    parameterized_body = "{{ruleSeverity}} {{ruleName}}: Postgres reported {{inputs.A.value}} deadlocks/min. Inspect ledger-service transaction patterns."
  }

  tags = ["natwest-demo", "infra", "postgres"]
}

# ---------------------------------------------------------------------------
# Detector 9 - Kafka ISR shrinks (replication health).
#
# Fires Critical on any ISR shrink. With a single broker / replication
# factor 1 we expect ZERO ISR shrinks; any non-zero rate signals broker
# instability. Metric exposed by jmx_exporter via the SignalFx-schema rule
# in helm/natwest-payments/templates/kafka.yaml's ConfigMap.
# ---------------------------------------------------------------------------
resource "signalfx_detector" "infra_kafka_isr_shrink" {
  count = local.obs_enabled ? 1 : 0

  name        = "[NatWest demo] Kafka ISR shrinks"
  description = "Critical when Kafka reports any in-sync-replica shrink within the last 2 minutes."

  program_text = <<-EOF
    A = data('kafka_server_replicamanager_isrshrinkspersec_oneminuterate').publish(label='isr_shrinks_per_sec')
    detect(when(A > 0, lasting='2m')).publish('Kafka ISR shrinking')
  EOF

  rule {
    detect_label       = "Kafka ISR shrinking"
    severity           = "Critical"
    notifications      = local.obs_email_notifications
    parameterized_body = "{{ruleSeverity}} {{ruleName}}: Kafka ISR is shrinking ({{inputs.A.value}}/s). Broker likely under memory or disk pressure."
  }

  tags = ["natwest-demo", "infra", "kafka"]
}

# ---------------------------------------------------------------------------
# Detector 10 - Kafka request 99p latency.
#
# Fires High when produce or fetch p99 latency exceeds 200ms sustained for
# 3 minutes. This is the broker-side counterpart to the application-side
# spans payment-initiation-service emits when producing to payments.settled.
# ---------------------------------------------------------------------------
resource "signalfx_detector" "infra_kafka_request_latency" {
  count = local.obs_enabled ? 1 : 0

  name        = "[NatWest demo] Kafka request 99p latency"
  description = "High when broker-side Produce or Fetch p99 latency exceeds 200ms for 3 minutes."

  program_text = <<-EOF
    produce = data('kafka_network_requestmetrics_totaltimems_99thpercentile', filter=filter('request','Produce')).publish(label='produce_p99_ms')
    fetch   = data('kafka_network_requestmetrics_totaltimems_99thpercentile', filter=filter('request','FetchConsumer')).publish(label='fetch_p99_ms')
    detect(when(produce > 200, lasting='3m')).publish('Kafka Produce p99 > 200ms for 3m')
    detect(when(fetch   > 200, lasting='3m')).publish('Kafka Fetch p99 > 200ms for 3m')
  EOF

  rule {
    detect_label       = "Kafka Produce p99 > 200ms for 3m"
    severity           = "Major"
    notifications      = local.obs_email_notifications
    parameterized_body = "{{ruleSeverity}} {{ruleName}}: Kafka broker Produce p99 is {{inputs.produce.value}}ms. Settlement edge in APM service map will reflect this."
  }

  rule {
    detect_label       = "Kafka Fetch p99 > 200ms for 3m"
    severity           = "Major"
    notifications      = local.obs_email_notifications
    parameterized_body = "{{ruleSeverity}} {{ruleName}}: Kafka broker Fetch p99 is {{inputs.fetch.value}}ms. settlement-service consumer lag may grow."
  }

  tags = ["natwest-demo", "infra", "kafka"]
}
