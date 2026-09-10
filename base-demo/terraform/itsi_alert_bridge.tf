# ITSI alert bridge - forward Splunk Observability detector firings into
# Splunk Enterprise (and from there into ITSI Episode Review).
#
# Architecture:
#   Splunk Observability detector fires
#     -> webhook integration POSTs JSON
#     -> HEC /services/collector/raw on the Splunk Enterprise EC2
#         (sourcetype=splunk_observability:alert, index=main)
#     -> ITSI correlation search runs every minute and emits notable events
#         from those HEC events into Episode Review.
#
# Enabled by default for the executive demo so the "detection -> Episode
# -> ticket" loop works out of the box. The local guard below still
# requires both Splunk Enterprise and Splunk Observability to be enabled
# AND a non-empty egress CIDR list -- so even with the variable defaulted
# to true, the security group is not widened until the operator confirms
# the egress allow-list for their realm.
#
# Roll-out (after applying this file):
#   1. Apply the additional security-group rule to allow inbound 8088 from
#      the Splunk Observability egress CIDRs (var.splunk_observability_egress_cidrs).
#   2. Re-apply observability.tf so the detectors pick up the new webhook
#      notification recipient.
#   3. Run scripts/07-itsi-bootstrap.sh - it installs the ITSI correlation
#      search defined in itsi/correlation-searches/o11y_to_itsi.conf.

variable "itsi_alert_bridge_enabled" {
  description = <<EOT
Forward Splunk Observability detector firings into ITSI via HEC.
Defaults to true so the executive demo's detection-to-Episode loop is
wired up out of the box. The local guard still requires:
  * splunk_enterprise_enabled = true
  * splunk_observability_enabled = true
  * splunk_observability_egress_cidrs populated with the o11y CIDRs
    listed at https://docs.splunk.com/observability/en/admin/notif-services/about-egress.html
so flipping this to true alone never widens the Splunk Enterprise
security group on its own.
EOT
  type        = bool
  default     = true
}

variable "splunk_observability_egress_cidrs" {
  description = <<EOT
Splunk Observability Cloud egress CIDRs that need to reach HEC on the
Splunk Enterprise EC2. Sourced from the o11y docs (varies by realm).
Default is the eu0 realm allow-list (matches the demo's eu-west-2
deployment); override in terraform.tfvars for any other realm.

Reference: https://docs.splunk.com/observability/en/admin/notif-services/about-egress.html
EOT
  type        = list(string)
  default     = ["3.248.59.20/32", "3.249.21.117/32", "52.31.69.49/32"]
}

locals {
  itsi_bridge_enabled = (
    var.itsi_alert_bridge_enabled
    && var.splunk_enterprise_enabled
    && length(var.splunk_observability_egress_cidrs) > 0
    && local.obs_enabled
  )
}

# ---------------------------------------------------------------------------
# Open HEC (8088) to Splunk Observability egress only.
#
# Restricted to the operator-supplied list - we never widen this to 0.0.0.0/0
# from terraform (codeguard-0-iac-security: "NEVER expose database/HEC services
# to all IP addresses"). If the egress list is empty the rule is not created.
# ---------------------------------------------------------------------------
resource "aws_security_group_rule" "splunk_hec_from_observability" {
  count = local.itsi_bridge_enabled ? 1 : 0

  type              = "ingress"
  from_port         = 8088
  to_port           = 8088
  protocol          = "tcp"
  cidr_blocks       = var.splunk_observability_egress_cidrs
  security_group_id = aws_security_group.splunk_enterprise[0].id
  description       = "HEC from Splunk Observability webhook egress (alert bridge)"
}

# ---------------------------------------------------------------------------
# Splunk Observability webhook integration.
#
# The webhook header includes the HEC token so HEC accepts the POST. We use
# the existing var.splunk_enterprise_hec_token rather than minting a second
# token to keep the per-token noise low for the demo.
# ---------------------------------------------------------------------------
resource "signalfx_webhook_integration" "itsi_bridge" {
  count = local.itsi_bridge_enabled ? 1 : 0

  name    = "[NatWest demo] ITSI alert bridge"
  enabled = true

  # Prefer the stable FQDN when DNS is enabled so the webhook target
  # survives an EIP rotation and lets us issue an ACM cert later
  # against itsi.splunk-observability.com without rewriting this URL.
  url = format(
    "https://%s:8088/services/collector/raw?sourcetype=splunk_observability:alert&index=main",
    (
      local.splunk_enterprise_dns_count > 0
      ? local.splunk_enterprise_fqdn
      : aws_instance.splunk_enterprise[0].public_ip
    ),
  )

  # HEC token authorization. Using a sensitive header rather than ?token= URL
  # so the token never appears in HTTP access logs. The signalfx provider
  # >=9.x exposes `headers` as a repeatable nested block, not a map.
  headers {
    header_key   = "Authorization"
    header_value = "Splunk ${var.splunk_enterprise_hec_token}"
  }
}

# ---------------------------------------------------------------------------
# Notification recipient string usable inside detector rules.
#
# The signalfx provider's notifications list expects 4 comma-separated parts
# for the Webhook type:
#
#     Webhook,<credentialId>,<secret>,<url>
#
# When referencing a pre-configured webhook integration, <secret> and <url>
# are taken from the integration's own configuration, so we leave them empty
# (trailing commas). The 2-part form `Webhook,<id>` looks tempting but the
# provider's notification parser rejects it with "invalid Webhook
# notification string ... not enough parts" because Sprintf-deserialises
# the string back into a struct that always wants 4 fields.
#
# Tested against splunk-terraform/signalfx 9.27.x.
#
# observability.tf detectors append this list to obs_email_notifications
# when the bridge is enabled.
# ---------------------------------------------------------------------------
locals {
  obs_itsi_webhook_notifications = local.itsi_bridge_enabled ? [
    "Webhook,${signalfx_webhook_integration.itsi_bridge[0].id},,"
  ] : []
}

output "itsi_alert_bridge_status" {
  description = "Diagnostic summary for the o11y -> ITSI alert bridge."
  # Marked sensitive because the integration ID flows through a sensitive
  # input (var.splunk_enterprise_hec_token via the webhook header). The map
  # contents themselves are operationally fine to print, but terraform's
  # taint analysis requires the explicit ack.
  sensitive = true
  value = {
    enabled             = local.itsi_bridge_enabled
    webhook_integration = local.itsi_bridge_enabled ? signalfx_webhook_integration.itsi_bridge[0].id : null
    hec_target_url = local.itsi_bridge_enabled ? format(
      "https://%s:8088 (sourcetype=splunk_observability:alert)",
      (
        local.splunk_enterprise_dns_count > 0
        ? local.splunk_enterprise_fqdn
        : aws_instance.splunk_enterprise[0].public_ip
      ),
    ) : null
    correlation_search  = "Splunk Observability - NatWest detector firings"
    notable_event_index = "itsi_tracked_alerts"
  }
}
