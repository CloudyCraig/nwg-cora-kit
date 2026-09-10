################################################################################
# Public SPA reverse proxy security group rules
#
# Why this file exists:
#   The AWS Organization SCP on this account explicitly denies
#   `elasticloadbalancing:CreateLoadBalancer` (verified by a 403
#   AccessDenied with a "service control policy" cause from a
#   `kubectl describe svc web-frontend` event log). That blocks the
#   "type: LoadBalancer" experience for the SPA, so we instead
#   front the in-cluster web-frontend Service with an nginx reverse
#   proxy running on the existing Splunk Enterprise EC2 instance.
#
# What this file adds:
#   1. EKS worker-node SG ingress for tcp/30598 (web-frontend NodePort)
#      and tcp/30680 (api-gateway NodePort) sourced from the Splunk
#      Enterprise EC2 SG. Source-by-SG (rather than CIDR) keeps the
#      hole tightly scoped: only the Splunk EC2 NIC can reach the
#      NodePorts, even though the worker subnets are public.
#   2. Splunk Enterprise SG ingress for tcp/80 from 0.0.0.0/0 so the
#      nginx reverse proxy is reachable from the internet. The
#      backend (NodePorts inside the VPC) stays unreachable from
#      outside thanks to (1).
#
# Toggling the whole thing off:
#   Set var.public_spa_proxy_enabled = false. The Helm chart's
#   frontend.enabled flag is independent: if the SCP is lifted later
#   you can flip frontend.service.type back to LoadBalancer, leave
#   this file's count at 0, and ignore the proxy script.
################################################################################

variable "public_spa_proxy_enabled" {
  description = <<EOT
Enable the SG rules that let the Splunk Enterprise EC2 nginx reverse
proxy front the in-cluster web-frontend SPA on port 80. Requires
var.splunk_enterprise_enabled = true. Set to false to remove the
public path entirely (e.g. when the org SCP allowing ELBs is lifted
and the SPA reverts to a `LoadBalancer`-typed Service).
EOT
  type        = bool
  default     = true
}

variable "public_spa_proxy_web_frontend_node_port" {
  description = <<EOT
NodePort exposed by the web-frontend Service. Must match
helm/natwest-payments/values.yaml -> frontend.service.nodePort.
EOT
  type        = number
  default     = 30598
}

variable "public_spa_proxy_api_gateway_node_port" {
  description = <<EOT
NodePort exposed by the api-gateway Service. Must match
helm/natwest-payments/values.yaml -> services.api-gateway.nodePort.
EOT
  type        = number
  default     = 30680
}

locals {
  public_spa_proxy_count = (
    var.public_spa_proxy_enabled
    && var.splunk_enterprise_enabled
  ) ? 1 : 0
}

################################################################################
# 1. EKS worker-node SG ingress from the Splunk EC2 SG
#
# The terraform-aws-modules/eks/aws module exposes the worker-node SG via
# `module.eks.node_security_group_id`. We reference it here rather than
# building a separate "all NodePorts" SG so the rule lives next to the
# rest of the SCP-aware infrastructure and is destroyed cleanly with
# `terraform destroy`.
################################################################################

resource "aws_security_group_rule" "node_ingress_web_frontend_nodeport" {
  count                    = local.public_spa_proxy_count
  type                     = "ingress"
  from_port                = var.public_spa_proxy_web_frontend_node_port
  to_port                  = var.public_spa_proxy_web_frontend_node_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.splunk_enterprise[0].id
  security_group_id        = module.eks.node_security_group_id
  description              = "web-frontend NodePort from Splunk EC2 nginx reverse proxy"
}

resource "aws_security_group_rule" "node_ingress_api_gateway_nodeport" {
  count                    = local.public_spa_proxy_count
  type                     = "ingress"
  from_port                = var.public_spa_proxy_api_gateway_node_port
  to_port                  = var.public_spa_proxy_api_gateway_node_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.splunk_enterprise[0].id
  security_group_id        = module.eks.node_security_group_id
  description              = "api-gateway NodePort from Splunk EC2 nginx reverse proxy"
}

################################################################################
# 2. Splunk EC2 SG ingress for HTTP from the internet
#
# Justification for 0.0.0.0/0:
#   The intent is a publicly-reachable demo URL, so a public ingress is
#   the requirement, not a misconfiguration. Risk is mitigated by
#   keeping the upstream NodePorts SG-scoped to the Splunk EC2 (above)
#   and by Splunk Web (8000) / mgmt (8089) / SSH (22) staying behind
#   operator CIDRs.
#
# Hardening recommendation when this becomes long-lived:
#   * Put a CloudFront distribution in front for TLS, WAF, and rate
#     limiting; restrict the SG to the CloudFront managed prefix list.
#   * Or replace 0.0.0.0/0 with the demo audience CIDRs once known.
################################################################################

resource "aws_security_group_rule" "splunk_public_http" {
  count             = local.public_spa_proxy_count
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.splunk_enterprise[0].id
  description       = "Public HTTP for the SPA reverse proxy (nginx to EKS NodePorts)"
}

################################################################################
# Outputs
################################################################################

output "public_spa_url" {
  description = <<EOT
Publicly-routable URL for the SPA, served by nginx on the Splunk
Enterprise EC2 instance. Prefers the stable FQDN when DNS is enabled
so RUM bookmarks and ThousandEyes synthetics survive an instance
reboot. null when the proxy is disabled or when the Splunk EC2
itself is disabled.
EOT
  value = local.public_spa_proxy_count == 1 ? format(
    "http://%s/",
    (
      local.splunk_enterprise_dns_count > 0
      ? local.splunk_enterprise_fqdn
      : aws_instance.splunk_enterprise[0].public_ip
    ),
  ) : null
}

output "public_spa_worker_node_ports" {
  description = "NodePorts that the public reverse proxy fronts (for ops debugging)."
  value = local.public_spa_proxy_count == 1 ? {
    web_frontend = var.public_spa_proxy_web_frontend_node_port
    api_gateway  = var.public_spa_proxy_api_gateway_node_port
  } : null
}
