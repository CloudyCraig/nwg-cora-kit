################################################################################
# Stable public addressing for the Splunk Enterprise instance
#
# Why this file exists:
#   The instance was launched with associate_public_ip_address = true, which
#   gives it an auto-assigned public IPv4 that is released on every stop/start
#   and replaced with a fresh address. That churn breaks anything pointed at
#   the box: the SPA reverse proxy URL, the ThousandEyes synthetic tests, the
#   ITSI demo URL in slides, hard-coded RUM SDK config, etc.
#
#   Pinning the box to an Elastic IP and projecting it through Route53 gives
#   us a stable hostname (itsi.splunk-observability.com) that survives reboots
#   and lets ThousandEyes' DNS Server test target a real name we control.
#
# Layout:
#   * aws_eip allocated in the VPC scope.
#   * aws_eip_association binds the EIP to the existing instance's primary
#     ENI. Associating an EIP REPLACES the auto-assigned public IP - clients
#     hard-coded to the previous IP must be migrated to the hostname.
#   * data.aws_route53_zone looks up the operator-supplied zone by name so
#     we don't hardcode the zone ID across environments.
#   * aws_route53_record creates / overwrites the A record for the chosen
#     hostname. allow_overwrite=true so we adopt any pre-existing record
#     (e.g. an A record left behind from a previous instance boot) without
#     a destroy/recreate cycle.
#
# Disable the whole feature with var.splunk_enterprise_dns_enabled = false.
################################################################################

variable "splunk_enterprise_dns_enabled" {
  description = <<EOT
Allocate an Elastic IP for the Splunk Enterprise instance and publish an
A record in the operator's Route53 zone. Requires
var.splunk_enterprise_enabled = true.
EOT
  type        = bool
  default     = true
}

variable "splunk_enterprise_dns_zone_name" {
  description = <<EOT
Route53 public hosted zone that already exists in the same AWS account.
The zone NS records must be delegated by the registrar of the parent
domain. Trailing dot is optional - both 'example.com' and 'example.com.'
are accepted.
EOT
  type        = string
  default     = "splunk-observability.com"
}

variable "splunk_enterprise_dns_record_name" {
  description = <<EOT
Hostname (subdomain) that will resolve to the Elastic IP. Provide the
LEFT-MOST label only; the zone name from
var.splunk_enterprise_dns_zone_name is appended automatically. Setting
this to "itsi" yields itsi.splunk-observability.com.
EOT
  type        = string
  default     = "itsi"
}

variable "splunk_enterprise_dns_ttl" {
  description = "TTL (seconds) for the Splunk Enterprise A record. Short by default to keep failover fast in a demo."
  type        = number
  default     = 60
}

locals {
  splunk_enterprise_dns_count = (
    var.splunk_enterprise_enabled && var.splunk_enterprise_dns_enabled
  ) ? 1 : 0

  splunk_enterprise_fqdn = format(
    "%s.%s",
    var.splunk_enterprise_dns_record_name,
    trimsuffix(var.splunk_enterprise_dns_zone_name, "."),
  )
}

################################################################################
# Elastic IP
################################################################################

resource "aws_eip" "splunk_enterprise" {
  count  = local.splunk_enterprise_dns_count
  domain = "vpc"

  tags = {
    Name = "${var.cluster_name}-splunk-enterprise"
    Role = "splunk-enterprise-public"
  }
}

resource "aws_eip_association" "splunk_enterprise" {
  count         = local.splunk_enterprise_dns_count
  instance_id   = aws_instance.splunk_enterprise[0].id
  allocation_id = aws_eip.splunk_enterprise[0].id
}

################################################################################
# Route53 A record
################################################################################

data "aws_route53_zone" "splunk_enterprise" {
  count        = local.splunk_enterprise_dns_count
  name         = var.splunk_enterprise_dns_zone_name
  private_zone = false
}

resource "aws_route53_record" "splunk_enterprise" {
  count           = local.splunk_enterprise_dns_count
  zone_id         = data.aws_route53_zone.splunk_enterprise[0].zone_id
  name            = local.splunk_enterprise_fqdn
  type            = "A"
  ttl             = var.splunk_enterprise_dns_ttl
  records         = [aws_eip.splunk_enterprise[0].public_ip]
  allow_overwrite = true
}

################################################################################
# Public HEC (8088) for ThousandEyes Streaming integration
#
# The Cisco ThousandEyes Add-on for Splunk receives Tests Stream / Alerts
# Stream / Activity Stream payloads via HEC tokens. ThousandEyes Cloud
# pushes those streams from outside our VPC, so HEC must be reachable on
# the public internet. The token itself authenticates each request.
#
# We create a SEPARATE SG rule rather than widening the existing
# `splunk_hec` rule because the existing rule (VPC-only) supports the
# in-cluster OTel Collector path, and we want both paths to coexist
# explicitly.
#
# Source CIDR is operator-tunable: leaving the default at 0.0.0.0/0 is
# the standard deployment pattern from the add-on docs (HEC token-based
# auth is the access control). To narrow it, set
# var.thousandeyes_egress_cidrs to the published TE egress prefix list
# from https://docs.thousandeyes.com/.
################################################################################

variable "thousandeyes_hec_ingress_enabled" {
  description = <<EOT
Add a public-internet inbound rule for HEC tcp/8088 so ThousandEyes
Cloud's Streaming integration can push Test / Alert / Activity data into
the Cisco ThousandEyes Add-on for Splunk. Requires
splunk_enterprise_dns_enabled = true.
EOT
  type        = bool
  default     = true
}

variable "thousandeyes_egress_cidrs" {
  description = <<EOT
CIDR blocks ThousandEyes Cloud streams from. Default 0.0.0.0/0 because
HEC tokens are the access control and the published egress prefix list
changes more often than is convenient for a demo. Tighten to the TE
docs' egress IP list when running production-like deployments.
EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "splunk_hec_public" {
  count = (
    local.splunk_enterprise_dns_count > 0
    && var.thousandeyes_hec_ingress_enabled
  ) ? 1 : 0
  type              = "ingress"
  from_port         = 8088
  to_port           = 8088
  protocol          = "tcp"
  cidr_blocks       = var.thousandeyes_egress_cidrs
  security_group_id = aws_security_group.splunk_enterprise[0].id
  description       = "HEC from public internet for ThousandEyes Streaming integration (token-authenticated)"
}

################################################################################
# Public splunkd management port (8089) for Splunk Observability Cloud
# Log Observer Connect (LOC).
#
# Why this exists:
#   The Splunk Observability `lo-connect` integration (id GhVhuhqAIAA in
#   the eu0 org) federates the APM Service Map "Logs" tab to a remote
#   Splunk Platform instance. To validate the integration on save,
#   Splunk Observability dials https://<domain>:8089/services/authorization/tokens
#   from its cloud egress IPs. Without a public 8089 ingress rule the
#   /v2/integration save returns:
#     HTTP 400 "Unable to connect to https://itsi.splunk-observability.com:8089/.."
#   and every subsequent APM "Logs" panel query also fails.
#
# Source CIDR:
#   Default 0.0.0.0/0 because (a) Splunk Observability does not publish
#   a stable egress prefix list for LOC, (b) the splunkd port itself
#   requires HTTP Basic auth, and (c) the integration uses a dedicated
#   `lo-connect` user with a non-privileged role (`user`) created by
#   the demo bootstrap. Tighten by setting var.splunk_observability_loc_cidrs
#   to the published Splunk Observability egress range for your realm
#   (eu0 sources from Splunk's AWS eu-west-1/-2 footprint).
#
# Defense in depth:
#   * splunkd 8089 enforces HTTP Basic auth against the local Splunk
#     authentication backend; anonymous requests get 401.
#   * The `lo-connect` Splunk user has only the `user` role, which
#     grants `search` against the indexes its role allows. No admin,
#     no edit_user, no edit_app.
#   * splunkd uses TLS by default (self-signed cert on this stack);
#     the LOC integration is configured with skip-verify because we
#     don't terminate a public CA cert on 8089 (only HEC has LE).
################################################################################

variable "splunk_observability_loc_enabled" {
  description = <<EOT
Open splunkd management port (tcp/8089) to the public internet so
Splunk Observability Cloud's Log Observer Connect (LOC) integration
can reach the Splunk Enterprise box. Required for the APM Service Map
"Logs" tab to populate. Disable if you front Splunk Enterprise with a
private connectivity solution (PrivateLink, VPN, etc.) and configure
LOC accordingly.
EOT
  type        = bool
  default     = true
}

variable "splunk_observability_loc_cidrs" {
  description = <<EOT
CIDR blocks Splunk Observability Cloud's LOC connector reaches the
splunkd management port from. Default 0.0.0.0/0 because Splunk does not
publish a stable egress prefix list for LOC and the splunkd port enforces
HTTP Basic auth + TLS. Tighten in production.
EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "splunkd_mgmt_public" {
  count = (
    local.splunk_enterprise_dns_count > 0
    && var.splunk_observability_loc_enabled
  ) ? 1 : 0
  type              = "ingress"
  from_port         = 8089
  to_port           = 8089
  protocol          = "tcp"
  cidr_blocks       = var.splunk_observability_loc_cidrs
  security_group_id = aws_security_group.splunk_enterprise[0].id
  description       = "splunkd 8089 from public internet for Splunk Observability LOC (basic-auth + TLS)"
}

################################################################################
# Public tcp/80 for the Let's Encrypt HTTP-01 challenge.
#
# Why this exists:
#   ThousandEyes Cloud's Streaming integration validates TLS reachability of
#   the HEC endpoint before it lets the operator save the integration. Splunk
#   Enterprise's default cert (CN=SplunkServerDefaultCert, issuer=SplunkCommonCA)
#   fails that check with "Invalid input: URL ... is not reachable due to:
#   TLS/SSL issue". To present a browser-trusted cert we issue a Let's
#   Encrypt cert against the public FQDN; certbot's HTTP-01 challenge needs
#   tcp/80 reachable from the public internet for the ~30-second window
#   during which the CA pokes at /.well-known/acme-challenge/.
#
#   Splunk does NOT serve anything on tcp/80 outside that window: certbot
#   --standalone binds the port only for the duration of the challenge and
#   then releases it. There is no "always-on" HTTP service on the box.
#
# Source CIDR: must be 0.0.0.0/0 because Let's Encrypt's validation traffic
# is multi-perspective and originates from a fleet of unannounced IPs.
# Authentication is via the ACME protocol (challenge token signed by the
# account key); HEC token-based auth still gates port 8088.
################################################################################

variable "letsencrypt_hec_enabled" {
  description = <<EOT
Issue a Let's Encrypt certificate for the Splunk Enterprise public FQDN
and configure HEC (tcp/8088) to present it. Required for the
ThousandEyes Cloud Streaming integration: TE Cloud refuses the
self-signed default cert with "TLS/SSL issue" during integration
creation. Requires splunk_enterprise_dns_enabled = true.

Inbound tcp/80 is already opened by aws_security_group_rule.splunk_public_http
in public_spa_proxy.tf for the SPA reverse proxy, so no additional SG
rule is needed for the certbot HTTP-01 challenge. The installer briefly
stops nginx around the challenge to coexist with the running SPA proxy.
EOT
  type        = bool
  default     = true
}

variable "letsencrypt_admin_email" {
  description = <<EOT
Contact email submitted to Let's Encrypt at account creation. Receives
30/14/7-day expiry warnings if renewal somehow stops working. Optional;
leaving this empty registers the account without a contact address
(--register-unsafely-without-email).
EOT
  type        = string
  default     = ""
}
