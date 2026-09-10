# Microsoft Teams alert bridge - opt-in forwarding of Splunk Observability
# detector firings into a Teams channel via an Incoming Webhook.
#
# Why this exists:
#   The customer's Path-to-Green assessment lists "Microsoft Teams
#   integration" as a GREEN capability in section 7 (Alerting). The
#   default demo only wires Email + the ITSI webhook bridge, so the
#   Teams row was previously a documented-but-not-demonstrated GREEN.
#   This file makes it a one-tfvar flip so the customer can literally
#   see their alerts land in Teams in seconds during the walkthrough.
#
# Architecture:
#   Splunk Observability detector fires
#     -> signalfx_webhook_integration POSTs the JSON payload
#     -> Microsoft Teams Incoming Webhook URL
#     -> Teams channel renders an actionable card.
#
#   The Teams webhook URL is treated as a secret (var sensitive = true)
#   even though it's "just" a URL - knowledge of it lets anyone post
#   arbitrary messages into the channel, so it has the same blast radius
#   as a low-privilege bot token. Never bake it into terraform.tfvars;
#   pass it via TF_VAR_microsoft_teams_webhook_url.
#
# How to enable (~30 seconds end-to-end):
#   1. In Teams: Channel -> Connectors -> Incoming Webhook -> Add.
#      Name it "Splunk Observability Alerts". Copy the URL Teams shows.
#   2. export TF_VAR_microsoft_teams_alert_enabled=true
#      export TF_VAR_microsoft_teams_webhook_url="https://outlook.office.com/..."
#   3. terraform -chdir=terraform apply
#   The same `obs_email_notifications` local that drives the detector
#   `notifications =` field gets a Webhook,<id>,, entry appended, so
#   every detector now also pings Teams on Critical AND Warning.

variable "microsoft_teams_alert_enabled" {
  description = <<EOT
Forward Splunk Observability detector firings to a Microsoft Teams
channel via an Incoming Webhook connector. Off by default because most
demo runs don't have a Teams channel to point at; flip on with
TF_VAR_microsoft_teams_alert_enabled=true plus a non-empty
TF_VAR_microsoft_teams_webhook_url. Both conditions must be true for
the webhook integration to be created (the local guard below enforces
this so a typo doesn't silently mute alerts).
EOT
  type        = bool
  default     = false
}

variable "microsoft_teams_webhook_url" {
  description = <<EOT
Microsoft Teams Incoming Webhook URL for the channel that should
receive Splunk Observability alerts. Treat as a secret: anyone with
this URL can post messages into the channel. Required (and only
honoured) when var.microsoft_teams_alert_enabled = true.

Create the URL in Teams: Channel -> Connectors -> Incoming Webhook ->
Add. Copy the URL Teams displays (it starts with
https://outlook.office.com/webhook/... or
https://<tenant>.webhook.office.com/...).

Pass via environment so it never lands in terraform.tfvars or state
diffs:
  export TF_VAR_microsoft_teams_webhook_url="https://..."
EOT
  type        = string
  default     = ""
  sensitive   = true

  validation {
    # Either off OR URL is set; we don't validate URL shape strictly
    # because Microsoft uses several formats (outlook.office.com,
    # <tenant>.webhook.office.com). Empty-when-enabled is the only
    # genuinely user-error case.
    condition     = !var.microsoft_teams_alert_enabled || length(var.microsoft_teams_webhook_url) > 0
    error_message = "microsoft_teams_webhook_url must be set when microsoft_teams_alert_enabled = true. Get the URL from Teams > Channel > Connectors > Incoming Webhook."
  }
}

locals {
  # Same guard pattern as itsi_alert_bridge.tf: the feature flag must
  # be on AND Splunk Observability must be enabled (no point standing
  # up a detector notification recipient if there are no detectors).
  teams_bridge_enabled = (
    var.microsoft_teams_alert_enabled
    && length(var.microsoft_teams_webhook_url) > 0
    && local.obs_enabled
  )
}

# ---------------------------------------------------------------------------
# Splunk Observability webhook integration pointed at the Teams URL.
#
# The signalfx_webhook_integration resource is the documented vehicle for
# Teams: Splunk's "Send alerts to Microsoft Teams" help page wraps the
# same REST surface this resource calls. The integration name surfaces in
# the Splunk UI under Settings -> Integrations so make it discoverable.
# ---------------------------------------------------------------------------
resource "signalfx_webhook_integration" "microsoft_teams" {
  count = local.teams_bridge_enabled ? 1 : 0

  name    = "[NatWest demo] Microsoft Teams alerts"
  enabled = true

  url = var.microsoft_teams_webhook_url
  # No `headers` block: Teams Incoming Webhooks accept anonymous POSTs
  # because the URL itself is the secret (per Microsoft's connector docs).
  # Adding an Authorization header would be rejected with 400.
}

# ---------------------------------------------------------------------------
# Notification recipient string for detector `notifications =` lists.
#
# Same 4-part Webhook,<id>,<secret>,<url> shape the signalfx provider
# requires (see itsi_alert_bridge.tf::obs_itsi_webhook_notifications for
# the full explanation). Trailing commas are mandatory.
# ---------------------------------------------------------------------------
locals {
  obs_teams_webhook_notifications = local.teams_bridge_enabled ? [
    "Webhook,${signalfx_webhook_integration.microsoft_teams[0].id},,"
  ] : []
}

output "microsoft_teams_alert_status" {
  description = "Diagnostic summary for the o11y -> Microsoft Teams alert bridge."
  # Sensitive because the integration ID is derived from the secret
  # webhook URL; we don't want it landing in plaintext build logs.
  sensitive = true
  value = {
    enabled             = local.teams_bridge_enabled
    webhook_integration = local.teams_bridge_enabled ? signalfx_webhook_integration.microsoft_teams[0].id : null
    # Don't echo the webhook URL even masked - if you need to verify
    # what's wired you can read `terraform state show` deliberately.
    target = local.teams_bridge_enabled ? "Microsoft Teams channel (Incoming Webhook)" : null
  }
}
