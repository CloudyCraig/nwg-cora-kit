output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API endpoint"
  value       = module.eks.cluster_endpoint
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "ecr_service_repo_url" {
  description = "ECR URL for the template microservice image"
  value       = aws_ecr_repository.app["natwest-payments-service"].repository_url
}

output "ecr_traffic_generator_repo_url" {
  description = "ECR URL for the traffic generator image"
  value       = aws_ecr_repository.app["natwest-payments-traffic-generator"].repository_url
}

output "ecr_ledger_service_java_repo_url" {
  description = "ECR URL for the polyglot Java ledger-service image"
  value       = aws_ecr_repository.app["natwest-payments-ledger-service-java"].repository_url
}

output "ecr_web_frontend_repo_url" {
  description = "ECR URL for the web frontend image (React + Splunk RUM)"
  value       = aws_ecr_repository.app["natwest-payments-web-frontend"].repository_url
}

output "ecr_chaos_controller_repo_url" {
  description = "ECR URL for the chaos-controller image (Flask + k8s client)"
  value       = aws_ecr_repository.app["natwest-payments-chaos-controller"].repository_url
}

output "splunk_token_secret_arn" {
  description = "ARN of the Splunk Observability token in Secrets Manager"
  value       = aws_secretsmanager_secret.splunk_token.arn
}

output "kubeconfig_command" {
  description = "Run this to configure kubectl for the new cluster"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

################################################################################
# Splunk Enterprise outputs
################################################################################

# Prefer the Elastic IP when the DNS feature is on so consumers (scripts,
# RUM SDK config, demo bookmarks) latch onto the stable address instead of
# the auto-assigned IP that disappears on the next instance stop/start.
output "splunk_enterprise_public_ip" {
  description = "Public IPv4 of the Splunk Enterprise instance (Elastic IP when DNS is enabled, auto-assigned otherwise; null when the box itself is disabled)."
  value = (
    var.splunk_enterprise_enabled
    ? (
      local.splunk_enterprise_dns_count > 0
      ? aws_eip.splunk_enterprise[0].public_ip
      : aws_instance.splunk_enterprise[0].public_ip
    )
    : null
  )
}

output "splunk_enterprise_private_ip" {
  description = "Private IPv4 of the Splunk Enterprise instance - use this for in-cluster collectors."
  value       = var.splunk_enterprise_enabled ? aws_instance.splunk_enterprise[0].private_ip : null
}

output "splunk_enterprise_fqdn" {
  description = "Fully-qualified hostname pointing at the Elastic IP (null when DNS is disabled)."
  value = (
    local.splunk_enterprise_dns_count > 0
    ? local.splunk_enterprise_fqdn
    : null
  )
}

output "splunk_enterprise_web_url" {
  description = "Splunk Web URL. Login as admin / smartway (or your overridden password). Uses the FQDN when DNS is enabled."
  value = var.splunk_enterprise_enabled ? format(
    "http://%s:8000",
    (
      local.splunk_enterprise_dns_count > 0
      ? local.splunk_enterprise_fqdn
      : aws_instance.splunk_enterprise[0].public_ip
    ),
  ) : null
}

output "splunk_enterprise_hec_endpoint" {
  description = <<EOT
HEC endpoint reachable from inside the VPC. Feed this to the OTel
Collector chart as splunkPlatform.endpoint to enable Log Observer
Connect-style log ingest plus metrics fan-out. We deliberately omit
the trailing /event suffix: the OTel splunk_hec exporter does not
rewrite the path per data type, and /services/collector accepts both
event and metric formats whereas /services/collector/event rejects
metric format with HTTP 400. The matching token is in
splunk_enterprise_hec_token (sensitive).
EOT
  value = var.splunk_enterprise_enabled ? format(
    "https://%s:8088/services/collector",
    aws_instance.splunk_enterprise[0].private_ip,
  ) : null
}

output "splunk_enterprise_hec_token" {
  description = "HEC token shared with the OTel Collector."
  value       = var.splunk_enterprise_enabled ? var.splunk_enterprise_hec_token : null
  sensitive   = true
}

output "splunk_enterprise_hec_token_firehose" {
  description = "HEC token used by Kinesis Firehose delivery streams (CloudTrail / VPC Flow / GuardDuty / EKS audit). Allow-list scoped to aws_* indexes only."
  value       = var.splunk_enterprise_enabled ? var.splunk_enterprise_hec_token_firehose : null
  sensitive   = true
}

output "splunk_enterprise_hec_token_scripts" {
  description = "HEC token used by demo helper scripts to write into nwpay_audit (chaos audit, ad-hoc banking events). Narrow allow-list."
  value       = var.splunk_enterprise_enabled ? var.splunk_enterprise_hec_token_scripts : null
  sensitive   = true
}

# Public HEC endpoint reachable from outside the VPC. The instance already
# has a public-internet HEC SG rule for ThousandEyes (see
# splunk_enterprise_dns.tf); the AWS Firehose -> HEC stack reuses that path
# but locks the source CIDRs to the AWS Firehose service prefix list.
output "splunk_enterprise_hec_endpoint_public" {
  description = <<EOT
Public HEC endpoint, suitable for AWS-managed log shippers (Kinesis
Firehose) that cannot reach the in-VPC private IP. Uses the FQDN when
DNS is enabled so the URL survives EIP rotations. Trailing path matches
the splunk_hec exporter convention: /services/collector accepts both
event and metric formats.
EOT
  value = var.splunk_enterprise_enabled ? format(
    "https://%s:8088/services/collector",
    (
      local.splunk_enterprise_dns_count > 0
      ? local.splunk_enterprise_fqdn
      : aws_instance.splunk_enterprise[0].public_ip
    ),
  ) : null
}

output "splunk_enterprise_instance_id" {
  description = "EC2 instance ID of the Splunk Enterprise box (use with `aws ssm start-session`)."
  value       = var.splunk_enterprise_enabled ? aws_instance.splunk_enterprise[0].id : null
}

output "splunk_enterprise_ssh_command" {
  description = "Convenience SSH command using the generated private key. Uses the FQDN when DNS is enabled, else the auto-assigned IP."
  value = var.splunk_enterprise_enabled ? format(
    "ssh -i %s/splunk-enterprise.pem ec2-user@%s",
    abspath(path.module),
    (
      local.splunk_enterprise_dns_count > 0
      ? local.splunk_enterprise_fqdn
      : aws_instance.splunk_enterprise[0].public_ip
    ),
  ) : null
}

output "splunk_enterprise_media_bucket" {
  description = "S3 bucket holding the staged install tarball + license."
  value       = var.splunk_enterprise_enabled ? aws_s3_bucket.splunk_media[0].id : null
}
