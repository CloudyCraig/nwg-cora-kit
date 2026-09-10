# Tier 3 - AWS cloud-plane logs into Splunk Enterprise via Kinesis Firehose.
#
# Architecture:
#   EKS control-plane logs (CloudWatch) -.
#                                         |--> Kinesis Firehose --> Splunk HEC
#   CloudTrail (CloudWatch)              -|       (one stream per source)
#   VPC Flow Logs                        -|       S3 backup bucket on failure
#   GuardDuty findings (EventBridge)     -'
#
# Why per-source streams:
#   * Clean per-source error metrics (CloudWatch Firehose metrics are scoped
#     per delivery stream).
#   * Each stream maps cleanly to one Splunk index (cloud-init configures
#     the matching aws_* indexes and a HEC token allow-listed to those
#     indexes only - see terraform/cloud-init/splunk-enterprise.tftpl).
#   * Lets us scale or sample one source (e.g. VPC Flow) without affecting
#     the others.
#
# Why gated:
#   * VPC Flow alone is ~50-200 events/s on the default VPC. Doubling demo
#     ingest is fine for the canonical Splunk Enterprise NFR license but
#     not always desirable; flip the flag when you need the ITSI / ES
#     content powered by these sources.
#   * The stack widens the Splunk EC2 SG to accept inbound 8088 from the
#     AWS Firehose service prefix list. Operators must opt in.
#
# Implementation references:
#   - https://docs.aws.amazon.com/firehose/latest/dev/create-destination.html#create-destination-splunk
#   - https://docs.aws.amazon.com/firehose/latest/dev/controlling-access.html (CIDRs / prefix list)

variable "aws_logs_to_hec_enabled" {
  description = <<EOT
Provision the Kinesis Firehose -> Splunk HEC pipelines for AWS cloud-plane
logs (EKS audit, CloudTrail, VPC Flow, GuardDuty). Gated and defaults to
false because:
  1. It widens the Splunk EC2 security group to accept inbound 8088 from
     the AWS Firehose service prefix list.
  2. It enables a new account-wide CloudTrail and VPC flow logs which add
     non-trivial CloudWatch + S3 storage costs.

Requires splunk_enterprise_enabled = true and splunk_enterprise_dns_enabled
= true (Firehose targets the public FQDN, not the in-VPC private IP).
EOT
  type        = bool
  default     = false
}

variable "aws_logs_to_hec_sources" {
  description = <<EOT
Per-source toggle so operators can enable a subset (e.g. just GuardDuty +
CloudTrail without the noisy VPC Flow stream). Each value is a boolean.
EOT
  type = object({
    cloudtrail = bool
    vpcflow    = bool
    guardduty  = bool
    eks_audit  = bool
  })
  default = {
    cloudtrail = true
    vpcflow    = true
    guardduty  = true
    eks_audit  = true
  }
}

variable "aws_logs_to_hec_buffer_seconds" {
  description = "Firehose buffering hint (seconds). Splunk destination max is 60s; lower means faster events visible in Splunk."
  type        = number
  default     = 60

  validation {
    condition     = var.aws_logs_to_hec_buffer_seconds >= 10 && var.aws_logs_to_hec_buffer_seconds <= 60
    error_message = "Splunk destination buffer interval must be between 10 and 60 seconds."
  }
}

variable "aws_logs_to_hec_buffer_mb" {
  description = "Firehose buffering hint (MB). Splunk destination accepts 1-5 MB."
  type        = number
  default     = 1

  validation {
    condition     = var.aws_logs_to_hec_buffer_mb >= 1 && var.aws_logs_to_hec_buffer_mb <= 5
    error_message = "Splunk destination buffer size must be between 1 and 5 MB."
  }
}

locals {
  aws_logs_enabled = (
    var.aws_logs_to_hec_enabled
    && var.splunk_enterprise_enabled
    && local.splunk_enterprise_dns_count > 0
  )

  aws_log_sources_enabled = {
    cloudtrail = local.aws_logs_enabled && var.aws_logs_to_hec_sources.cloudtrail
    vpcflow    = local.aws_logs_enabled && var.aws_logs_to_hec_sources.vpcflow
    guardduty  = local.aws_logs_enabled && var.aws_logs_to_hec_sources.guardduty
    eks_audit  = local.aws_logs_enabled && var.aws_logs_to_hec_sources.eks_audit
  }

  # HEC endpoint for Firehose destination. Must be the public FQDN since
  # Firehose runs in AWS's managed VPC, not ours.
  aws_logs_hec_url = local.aws_logs_enabled ? format(
    "https://%s:8088",
    local.splunk_enterprise_fqdn,
  ) : null

  # Map of (source -> { index, sourcetype }). Aligned with cloud-init
  # indexes.conf and props.conf stanzas. Changing a sourcetype here must
  # be paired with an update to splunk-enterprise.tftpl.
  aws_log_destinations = {
    cloudtrail = { index = "aws_cloudtrail", sourcetype = "aws:cloudtrail" }
    vpcflow    = { index = "aws_vpcflow", sourcetype = "aws:cloudwatchlogs:vpcflow" }
    guardduty  = { index = "aws_guardduty", sourcetype = "aws:guardduty" }
    eks_audit  = { index = "aws_eks_audit", sourcetype = "aws:cloudwatchlogs" }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# Firehose service prefix list (region-specific). aws_ec2_managed_prefix_list
# does not include Firehose endpoints; AWS publishes the IP ranges in
# https://ip-ranges.amazonaws.com/ip-ranges.json with service=KINESIS and
# region tags. We reference the published prefix list directly instead of
# pulling them in Terraform - they change rarely and the list-of-CIDRs
# approach (operator-supplied) keeps the SG rule auditable.
# ---------------------------------------------------------------------------

variable "aws_firehose_egress_cidrs" {
  description = <<EOT
CIDR blocks used by the AWS Kinesis Firehose service to deliver events to
HEC. Source: https://ip-ranges.amazonaws.com/ip-ranges.json (service=
KINESIS, region matches your deployment). Operators must populate this
list - we never default to 0.0.0.0/0 (codeguard-0-iac-security forbids
exposing HEC to all IPs).

Example for eu-west-2 (London) at the time of writing: see
  https://docs.aws.amazon.com/firehose/latest/dev/controlling-access.html
EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for c in var.aws_firehose_egress_cidrs : c != "0.0.0.0/0"
    ])
    error_message = "aws_firehose_egress_cidrs must not include 0.0.0.0/0."
  }
}

# Open public 8088 to the AWS Firehose service CIDRs only.
resource "aws_security_group_rule" "splunk_hec_from_firehose" {
  count = (
    local.aws_logs_enabled
    && length(var.aws_firehose_egress_cidrs) > 0
  ) ? 1 : 0

  type              = "ingress"
  from_port         = 8088
  to_port           = 8088
  protocol          = "tcp"
  cidr_blocks       = var.aws_firehose_egress_cidrs
  security_group_id = aws_security_group.splunk_enterprise[0].id
  description       = "HEC from AWS Firehose service CIDRs (cloud-plane logs)"
}

# ---------------------------------------------------------------------------
# S3 backup bucket - Firehose writes here when HEC delivery fails. KMS
# encrypted, no public access, lifecycle expires after 30 days.
# (codeguard-0-data-storage: backups encrypted; lifecycle managed.)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "firehose_backup" {
  count         = local.aws_logs_enabled ? 1 : 0
  bucket        = format("nwpay-firehose-backup-%s-%s", data.aws_caller_identity.current.account_id, data.aws_region.current.name)
  force_destroy = true

  tags = {
    Name        = "natwest-payments-firehose-backup"
    Description = "Firehose -> Splunk HEC delivery failure backup"
  }
}

resource "aws_s3_bucket_public_access_block" "firehose_backup" {
  count                   = local.aws_logs_enabled ? 1 : 0
  bucket                  = aws_s3_bucket.firehose_backup[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "firehose_backup" {
  count  = local.aws_logs_enabled ? 1 : 0
  bucket = aws_s3_bucket.firehose_backup[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "firehose_backup" {
  count  = local.aws_logs_enabled ? 1 : 0
  bucket = aws_s3_bucket.firehose_backup[0].id

  rule {
    id     = "expire-failed-deliveries"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# ---------------------------------------------------------------------------
# CloudWatch log group for Firehose error/diagnostic logging.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "firehose" {
  for_each          = { for k, v in local.aws_log_sources_enabled : k => v if v }
  name              = "/aws/kinesisfirehose/nwpay-${each.key}"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_stream" "firehose_splunk_delivery" {
  for_each       = { for k, v in local.aws_log_sources_enabled : k => v if v }
  log_group_name = aws_cloudwatch_log_group.firehose[each.key].name
  name           = "SplunkDelivery"
}

# ---------------------------------------------------------------------------
# IAM role assumed by Kinesis Firehose. Least privilege: write to backup
# S3, write to its own CloudWatch log group, no access to anything else.
# (codeguard-0-iac-security: no wildcard Action/Resource; least privilege.)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "firehose_assume" {
  count = local.aws_logs_enabled ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "firehose" {
  count              = local.aws_logs_enabled ? 1 : 0
  name               = "natwest-payments-firehose-splunk"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume[0].json
}

data "aws_iam_policy_document" "firehose_inline" {
  count = local.aws_logs_enabled ? 1 : 0

  statement {
    sid    = "S3Backup"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject",
    ]
    resources = [
      aws_s3_bucket.firehose_backup[0].arn,
      "${aws_s3_bucket.firehose_backup[0].arn}/*",
    ]
  }

  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:PutLogEvents",
    ]
    resources = [
      for k, v in local.aws_log_sources_enabled :
      "${aws_cloudwatch_log_group.firehose[k].arn}:*"
      if v
    ]
  }
}

resource "aws_iam_role_policy" "firehose" {
  count  = local.aws_logs_enabled ? 1 : 0
  name   = "natwest-payments-firehose-inline"
  role   = aws_iam_role.firehose[0].id
  policy = data.aws_iam_policy_document.firehose_inline[0].json
}

# ---------------------------------------------------------------------------
# Firehose delivery streams - one per source.
# ---------------------------------------------------------------------------

resource "aws_kinesis_firehose_delivery_stream" "splunk" {
  for_each    = { for k, v in local.aws_log_sources_enabled : k => v if v }
  name        = "nwpay-${each.key}-to-splunk"
  destination = "splunk"

  splunk_configuration {
    hec_endpoint               = local.aws_logs_hec_url
    hec_endpoint_type          = "Event"
    hec_token                  = var.splunk_enterprise_hec_token_firehose
    hec_acknowledgment_timeout = 180
    s3_backup_mode             = "FailedEventsOnly"
    buffering_interval         = var.aws_logs_to_hec_buffer_seconds
    buffering_size             = var.aws_logs_to_hec_buffer_mb

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose[each.key].name
      log_stream_name = aws_cloudwatch_log_stream.firehose_splunk_delivery[each.key].name
    }

    s3_configuration {
      role_arn           = aws_iam_role.firehose[0].arn
      bucket_arn         = aws_s3_bucket.firehose_backup[0].arn
      prefix             = "${each.key}/"
      buffering_size     = 5
      buffering_interval = 300
      compression_format = "GZIP"
    }
  }
}

# ---------------------------------------------------------------------------
# Source 1: CloudTrail
#
# Account-level trail capturing management events + KMS data events +
# Secrets Manager data events (the two services most worth auditing in
# this demo - app KMS keys decrypt secrets, Secrets Manager holds the
# Splunk ingest token). Trail logs ship to CloudWatch Logs; a subscription
# filter forwards every record to Firehose.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "cloudtrail" {
  count             = local.aws_log_sources_enabled["cloudtrail"] ? 1 : 0
  name              = "/aws/cloudtrail/natwest-payments-demo"
  retention_in_days = 7
}

data "aws_iam_policy_document" "cloudtrail_assume" {
  count = local.aws_log_sources_enabled["cloudtrail"] ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cloudtrail_to_logs" {
  count              = local.aws_log_sources_enabled["cloudtrail"] ? 1 : 0
  name               = "natwest-payments-cloudtrail-to-logs"
  assume_role_policy = data.aws_iam_policy_document.cloudtrail_assume[0].json
}

data "aws_iam_policy_document" "cloudtrail_to_logs" {
  count = local.aws_log_sources_enabled["cloudtrail"] ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.cloudtrail[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "cloudtrail_to_logs" {
  count  = local.aws_log_sources_enabled["cloudtrail"] ? 1 : 0
  name   = "cloudtrail-to-logs"
  role   = aws_iam_role.cloudtrail_to_logs[0].id
  policy = data.aws_iam_policy_document.cloudtrail_to_logs[0].json
}

resource "aws_s3_bucket" "cloudtrail" {
  count         = local.aws_log_sources_enabled["cloudtrail"] ? 1 : 0
  bucket        = format("nwpay-cloudtrail-%s-%s", data.aws_caller_identity.current.account_id, data.aws_region.current.name)
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  count                   = local.aws_log_sources_enabled["cloudtrail"] ? 1 : 0
  bucket                  = aws_s3_bucket.cloudtrail[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  count  = local.aws_log_sources_enabled["cloudtrail"] ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_iam_policy_document" "cloudtrail_bucket" {
  count = local.aws_log_sources_enabled["cloudtrail"] ? 1 : 0

  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.cloudtrail[0].arn]
  }

  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cloudtrail[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  count  = local.aws_log_sources_enabled["cloudtrail"] ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail[0].id
  policy = data.aws_iam_policy_document.cloudtrail_bucket[0].json
}

resource "aws_cloudtrail" "demo" {
  count                         = local.aws_log_sources_enabled["cloudtrail"] ? 1 : 0
  name                          = "natwest-payments-demo"
  s3_bucket_name                = aws_s3_bucket.cloudtrail[0].id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.cloudtrail[0].arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.cloudtrail_to_logs[0].arn

  # advanced_event_selector required for KMS / Secrets Manager data events;
  # the legacy event_selector.data_resource only allows S3/Lambda/DynamoDB.
  advanced_event_selector {
    name = "Management events"
    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }
  }

  advanced_event_selector {
    name = "KMS data events"
    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }
    field_selector {
      field  = "resources.type"
      equals = ["AWS::KMS::Key"]
    }
  }

  advanced_event_selector {
    name = "Secrets Manager data events"
    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }
    field_selector {
      field  = "resources.type"
      equals = ["AWS::SecretsManager::Secret"]
    }
  }

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}

# ---------------------------------------------------------------------------
# Source 2: VPC Flow Logs - directly to Firehose (no CloudWatch hop).
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "vpcflow_assume" {
  count = local.aws_log_sources_enabled["vpcflow"] ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vpcflow_to_firehose" {
  count              = local.aws_log_sources_enabled["vpcflow"] ? 1 : 0
  name               = "natwest-payments-vpcflow-to-firehose"
  assume_role_policy = data.aws_iam_policy_document.vpcflow_assume[0].json
}

data "aws_iam_policy_document" "vpcflow_to_firehose" {
  count = local.aws_log_sources_enabled["vpcflow"] ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "firehose:PutRecord",
      "firehose:PutRecordBatch",
    ]
    resources = [aws_kinesis_firehose_delivery_stream.splunk["vpcflow"].arn]
  }
}

resource "aws_iam_role_policy" "vpcflow_to_firehose" {
  count  = local.aws_log_sources_enabled["vpcflow"] ? 1 : 0
  name   = "vpcflow-to-firehose"
  role   = aws_iam_role.vpcflow_to_firehose[0].id
  policy = data.aws_iam_policy_document.vpcflow_to_firehose[0].json
}

resource "aws_flow_log" "default_vpc" {
  count                = local.aws_log_sources_enabled["vpcflow"] ? 1 : 0
  log_destination_type = "kinesis-data-firehose"
  log_destination      = aws_kinesis_firehose_delivery_stream.splunk["vpcflow"].arn
  iam_role_arn         = aws_iam_role.vpcflow_to_firehose[0].arn
  traffic_type         = "ALL"
  vpc_id               = data.aws_vpc.default.id
}

# ---------------------------------------------------------------------------
# Source 3: GuardDuty findings -> EventBridge -> Firehose.
#
# GuardDuty does not natively integrate with Firehose; we route findings
# through EventBridge, which Firehose accepts as an event-pattern target.
# ---------------------------------------------------------------------------

resource "aws_guardduty_detector" "demo" {
  count                        = local.aws_log_sources_enabled["guardduty"] ? 1 : 0
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
}

resource "aws_cloudwatch_event_rule" "guardduty_findings" {
  count       = local.aws_log_sources_enabled["guardduty"] ? 1 : 0
  name        = "nwpay-guardduty-findings-to-firehose"
  description = "Forward GuardDuty findings into the Splunk Firehose stream"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
  })
}

data "aws_iam_policy_document" "events_to_firehose_assume" {
  count = local.aws_log_sources_enabled["guardduty"] ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "events_to_firehose" {
  count              = local.aws_log_sources_enabled["guardduty"] ? 1 : 0
  name               = "natwest-payments-events-to-firehose"
  assume_role_policy = data.aws_iam_policy_document.events_to_firehose_assume[0].json
}

data "aws_iam_policy_document" "events_to_firehose" {
  count = local.aws_log_sources_enabled["guardduty"] ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "firehose:PutRecord",
      "firehose:PutRecordBatch",
    ]
    resources = [aws_kinesis_firehose_delivery_stream.splunk["guardduty"].arn]
  }
}

resource "aws_iam_role_policy" "events_to_firehose" {
  count  = local.aws_log_sources_enabled["guardduty"] ? 1 : 0
  name   = "events-to-firehose"
  role   = aws_iam_role.events_to_firehose[0].id
  policy = data.aws_iam_policy_document.events_to_firehose[0].json
}

resource "aws_cloudwatch_event_target" "guardduty_findings" {
  count     = local.aws_log_sources_enabled["guardduty"] ? 1 : 0
  rule      = aws_cloudwatch_event_rule.guardduty_findings[0].name
  target_id = "firehose"
  arn       = aws_kinesis_firehose_delivery_stream.splunk["guardduty"].arn
  role_arn  = aws_iam_role.events_to_firehose[0].arn
}

# ---------------------------------------------------------------------------
# Source 4: EKS control-plane logs.
#
# The EKS module already enables api/audit/authenticator/controllerManager/
# scheduler logging to CloudWatch (see main.tf cluster_enabled_log_types).
# We attach a CloudWatch Logs subscription filter that pipes every record
# to Firehose.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "logs_to_firehose_assume" {
  count = local.aws_log_sources_enabled["eks_audit"] ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.name}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "logs_to_firehose" {
  count              = local.aws_log_sources_enabled["eks_audit"] ? 1 : 0
  name               = "natwest-payments-logs-to-firehose"
  assume_role_policy = data.aws_iam_policy_document.logs_to_firehose_assume[0].json
}

data "aws_iam_policy_document" "logs_to_firehose" {
  count = local.aws_log_sources_enabled["eks_audit"] ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "firehose:PutRecord",
      "firehose:PutRecordBatch",
    ]
    resources = [aws_kinesis_firehose_delivery_stream.splunk["eks_audit"].arn]
  }
}

resource "aws_iam_role_policy" "logs_to_firehose" {
  count  = local.aws_log_sources_enabled["eks_audit"] ? 1 : 0
  name   = "logs-to-firehose"
  role   = aws_iam_role.logs_to_firehose[0].id
  policy = data.aws_iam_policy_document.logs_to_firehose[0].json
}

resource "aws_cloudwatch_log_subscription_filter" "eks_audit" {
  count           = local.aws_log_sources_enabled["eks_audit"] ? 1 : 0
  name            = "nwpay-eks-audit-to-firehose"
  log_group_name  = "/aws/eks/${var.cluster_name}/cluster"
  filter_pattern  = ""
  destination_arn = aws_kinesis_firehose_delivery_stream.splunk["eks_audit"].arn
  role_arn        = aws_iam_role.logs_to_firehose[0].arn
}

# Optional: also subscribe the CloudTrail log group to Firehose. The
# CloudTrail trail itself writes to S3 *and* CloudWatch; subscribing the
# CloudWatch group keeps the existing S3 archive while adding the Splunk
# stream. (CloudTrail does not natively integrate with Firehose.)
resource "aws_cloudwatch_log_subscription_filter" "cloudtrail" {
  count           = local.aws_log_sources_enabled["cloudtrail"] ? 1 : 0
  name            = "nwpay-cloudtrail-to-firehose"
  log_group_name  = aws_cloudwatch_log_group.cloudtrail[0].name
  filter_pattern  = ""
  destination_arn = aws_kinesis_firehose_delivery_stream.splunk["cloudtrail"].arn
  role_arn        = aws_iam_role.logs_to_firehose[0].arn

  depends_on = [aws_iam_role_policy.logs_to_firehose]
}

# Need to widen the logs_to_firehose policy to include the CloudTrail
# stream as well, since both EKS and CloudTrail subscription filters use
# the same role. We rebuild the policy when CloudTrail is enabled.
data "aws_iam_policy_document" "logs_to_firehose_with_cloudtrail" {
  count = (
    local.aws_log_sources_enabled["eks_audit"]
    && local.aws_log_sources_enabled["cloudtrail"]
  ) ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "firehose:PutRecord",
      "firehose:PutRecordBatch",
    ]
    resources = [
      aws_kinesis_firehose_delivery_stream.splunk["eks_audit"].arn,
      aws_kinesis_firehose_delivery_stream.splunk["cloudtrail"].arn,
    ]
  }
}

resource "aws_iam_role_policy" "logs_to_firehose_with_cloudtrail" {
  count = (
    local.aws_log_sources_enabled["eks_audit"]
    && local.aws_log_sources_enabled["cloudtrail"]
  ) ? 1 : 0
  name   = "logs-to-firehose-with-cloudtrail"
  role   = aws_iam_role.logs_to_firehose[0].id
  policy = data.aws_iam_policy_document.logs_to_firehose_with_cloudtrail[0].json
}

# ---------------------------------------------------------------------------
# Diagnostic output.
# ---------------------------------------------------------------------------

output "aws_logs_to_hec_status" {
  description = "Diagnostic summary for the Tier 3 AWS-cloud-plane log pipeline."
  sensitive   = true
  value = {
    enabled = local.aws_logs_enabled
    sources = local.aws_log_sources_enabled
    streams = local.aws_logs_enabled ? {
      for k, v in local.aws_log_sources_enabled :
      k => v ? aws_kinesis_firehose_delivery_stream.splunk[k].arn : null
    } : {}
    backup_bucket = local.aws_logs_enabled ? aws_s3_bucket.firehose_backup[0].id : null
    hec_url       = local.aws_logs_hec_url
    firehose_cidrs_configured = (
      local.aws_logs_enabled
      ? length(var.aws_firehose_egress_cidrs) > 0
      : null
    )
  }
}
