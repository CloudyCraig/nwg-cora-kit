################################################################################
# Splunk Enterprise (single-node, in-VPC)
#
# Why this exists:
#   The Splunk Observability Cloud /v1/log HEC endpoint only accepts arbitrary
#   application logs when a Log Observer Connect integration with a Splunk
#   Platform stack is in place. Posting raw filelog records to the o11y HEC
#   without LOC returns 404 (we tried, see collector/values.yaml). To unlock
#   the "logs in context" pivot from APM trace to log line in the Splunk
#   Observability UI we need a real Splunk Platform endpoint that LOC can
#   federate against. This file stands up exactly that, in the same default
#   VPC as the EKS cluster, so the OTel Collector can ship logs over private
#   addressing.
#
# Layout:
#   * KMS-encrypted S3 bucket holds the install media + NFR license. The
#     bucket and bucket policy block all public access; objects are only
#     readable by the EC2 instance role.
#   * Instance role + profile: read-only on the staging bucket, plus the
#     SSM-managed-instance policy so we can shell in via Session Manager
#     without exposing port 22 if operators prefer (port 22 is still locked
#     down to operator CIDRs as a backup).
#   * Security group:
#       8000  - Splunk Web (operator CIDRs only)
#       8088  - HEC (VPC CIDR only - the OTel Collector pod IPs route here
#                via the VPC CNI)
#       8089  - Splunk REST/management (operator CIDRs only)
#       9997  - Splunk-to-Splunk forwarding (VPC CIDR only)
#       22    - SSH (operator CIDRs only)
#   * EC2 instance: AL2023, c5.4xlarge by default, gp3 root, instance role
#     attached. user-data renders cloud-init/splunk-enterprise.tftpl with the
#     bucket, license/media keys, admin password, and HEC token baked in.
#   * Bucket uploads are done via null_resource + aws s3 cp instead of
#     aws_s3_object so terraform doesn't have to read 1.7 GB of tarball into
#     state on every plan.
################################################################################

locals {
  splunk_enterprise_count = var.splunk_enterprise_enabled ? 1 : 0

  # Web/management surface defaults to the same operator CIDRs that already
  # gate the EKS public API endpoint, so we don't open a second hole in the
  # firewall. Override with var.splunk_enterprise_web_allowed_cidrs when the
  # operator subnets differ.
  splunk_web_cidrs = (
    var.splunk_enterprise_web_allowed_cidrs == null
    ? var.allowed_public_api_cidrs
    : var.splunk_enterprise_web_allowed_cidrs
  )

  # S3 keys under which the cloud-init script expects to find the assets.
  # Versioning the key by basename means uploading a different installer
  # tarball produces a fresh object instead of silently overwriting the old
  # one (helpful when bumping Splunk versions).
  splunk_tarball_key = format("media/%s", basename(var.splunk_enterprise_media_path))
  splunk_license_key = format("license/%s", basename(var.splunk_enterprise_license_path))

  # Path the Let's Encrypt installer is staged at. Hosting it in S3 instead of
  # base64-embedding it inside cloud-init keeps the rendered user_data under
  # the EC2 16,384-byte hard limit (the script itself is ~16 KB and balloons
  # past the limit once base64-encoded into the YAML). The cloud-init
  # bootstrap wrapper aws-s3-cps it down at first boot before invoking it.
  splunk_letsencrypt_installer_key = "scripts/install_letsencrypt_hec.sh"
  splunk_letsencrypt_installer_src = "${path.module}/../scripts/lib/install_letsencrypt_hec.sh"
}

################################################################################
# Pre-flight: confirm the operator-supplied paths exist before we provision
# anything. fileexists() returns a hard error at plan time so we fail fast
# rather than mid-cloud-init.
################################################################################

check "splunk_enterprise_media_present" {
  assert {
    condition = (
      !var.splunk_enterprise_enabled
      || fileexists(var.splunk_enterprise_media_path)
    )
    error_message = "splunk_enterprise_media_path does not exist on disk: ${var.splunk_enterprise_media_path}"
  }
  assert {
    condition = (
      !var.splunk_enterprise_enabled
      || fileexists(var.splunk_enterprise_license_path)
    )
    error_message = "splunk_enterprise_license_path does not exist on disk: ${var.splunk_enterprise_license_path}"
  }
}

################################################################################
# Latest AL2023 AMI (matches the EKS node base for consistency).
################################################################################

data "aws_ami" "al2023" {
  count       = local.splunk_enterprise_count
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

################################################################################
# KMS-encrypted, BPA-locked S3 bucket for install media + license
################################################################################

resource "aws_kms_key" "splunk_media" {
  count                   = local.splunk_enterprise_count
  description             = "KMS key for Splunk Enterprise install media bucket (${var.cluster_name})"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "splunk_media" {
  count         = local.splunk_enterprise_count
  name          = "alias/${var.cluster_name}-splunk-media"
  target_key_id = aws_kms_key.splunk_media[0].key_id
}

resource "random_id" "splunk_media_suffix" {
  count       = local.splunk_enterprise_count
  byte_length = 4
}

resource "aws_s3_bucket" "splunk_media" {
  count         = local.splunk_enterprise_count
  bucket        = "${var.cluster_name}-splunk-media-${random_id.splunk_media_suffix[0].hex}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "splunk_media" {
  count                   = local.splunk_enterprise_count
  bucket                  = aws_s3_bucket.splunk_media[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "splunk_media" {
  count  = local.splunk_enterprise_count
  bucket = aws_s3_bucket.splunk_media[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.splunk_media[0].arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "splunk_media" {
  count  = local.splunk_enterprise_count
  bucket = aws_s3_bucket.splunk_media[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

# Force HTTPS-only access. AWS managed S3 endpoints already serve TLS but
# without an explicit deny aws:SecureTransport=false, an in-VPC instance
# could still be configured to use the deprecated HTTP endpoint.
resource "aws_s3_bucket_policy" "splunk_media" {
  count  = local.splunk_enterprise_count
  bucket = aws_s3_bucket.splunk_media[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.splunk_media[0].arn,
          "${aws_s3_bucket.splunk_media[0].arn}/*",
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

################################################################################
# Stage installer + license to S3 via local aws s3 cp.
#
# Why null_resource instead of aws_s3_object: aws_s3_object reads the source
# file into memory to compute an MD5 etag on every plan, which means a 1.7 GB
# tarball blows up plan times and bloats the lock file. null_resource +
# triggers={file_sha256(...)} replicates the change-detection without ever
# pulling the bytes into terraform.
################################################################################

resource "null_resource" "upload_splunk_media" {
  count = local.splunk_enterprise_count

  triggers = {
    bucket        = aws_s3_bucket.splunk_media[0].id
    media_sha     = filesha256(var.splunk_enterprise_media_path)
    license_sha   = filesha256(var.splunk_enterprise_license_path)
    installer_sha = filesha256(local.splunk_letsencrypt_installer_src)
    region        = var.region
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      echo "[stage] uploading $(basename '${var.splunk_enterprise_media_path}') to s3://${aws_s3_bucket.splunk_media[0].id}/${local.splunk_tarball_key}"
      aws s3 cp \
        --region ${var.region} \
        --only-show-errors \
        '${var.splunk_enterprise_media_path}' \
        's3://${aws_s3_bucket.splunk_media[0].id}/${local.splunk_tarball_key}'

      echo "[stage] uploading $(basename '${var.splunk_enterprise_license_path}') to s3://${aws_s3_bucket.splunk_media[0].id}/${local.splunk_license_key}"
      aws s3 cp \
        --region ${var.region} \
        --only-show-errors \
        '${var.splunk_enterprise_license_path}' \
        's3://${aws_s3_bucket.splunk_media[0].id}/${local.splunk_license_key}'

      # Staging the Let's Encrypt HEC installer alongside the media keeps the
      # cloud-init template tiny - inlining a base64 copy of this script blew
      # past the EC2 16,384-byte user_data limit and broke `terraform plan`.
      # Cloud-init aws-s3-cps it at boot (see splunk-enterprise.tftpl
      # /opt/splunk-letsencrypt-bootstrap.sh).
      echo "[stage] uploading install_letsencrypt_hec.sh to s3://${aws_s3_bucket.splunk_media[0].id}/${local.splunk_letsencrypt_installer_key}"
      aws s3 cp \
        --region ${var.region} \
        --only-show-errors \
        '${local.splunk_letsencrypt_installer_src}' \
        's3://${aws_s3_bucket.splunk_media[0].id}/${local.splunk_letsencrypt_installer_key}'
    EOT
  }

  depends_on = [
    aws_s3_bucket_public_access_block.splunk_media,
    aws_s3_bucket_server_side_encryption_configuration.splunk_media,
    aws_s3_bucket_policy.splunk_media,
  ]
}

################################################################################
# IAM role + instance profile
################################################################################

data "aws_iam_policy_document" "splunk_assume_role" {
  count = local.splunk_enterprise_count

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "splunk_enterprise" {
  count              = local.splunk_enterprise_count
  name               = "${var.cluster_name}-splunk-enterprise"
  assume_role_policy = data.aws_iam_policy_document.splunk_assume_role[0].json
}

# SSM Session Manager support so operators can shell in without SSH if they
# remove their /32 from var.splunk_enterprise_web_allowed_cidrs.
resource "aws_iam_role_policy_attachment" "splunk_enterprise_ssm" {
  count      = local.splunk_enterprise_count
  role       = aws_iam_role.splunk_enterprise[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "splunk_media_read" {
  count = local.splunk_enterprise_count

  statement {
    sid    = "ReadSplunkStagingObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]
    resources = ["${aws_s3_bucket.splunk_media[0].arn}/*"]
  }

  statement {
    sid    = "ListSplunkStagingBucket"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [aws_s3_bucket.splunk_media[0].arn]
  }

  # Decrypt objects encrypted with the bucket KMS key.
  statement {
    sid       = "DecryptSplunkStagingObjects"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.splunk_media[0].arn]
  }
}

resource "aws_iam_role_policy" "splunk_media_read" {
  count  = local.splunk_enterprise_count
  name   = "splunk-media-read"
  role   = aws_iam_role.splunk_enterprise[0].id
  policy = data.aws_iam_policy_document.splunk_media_read[0].json
}

resource "aws_iam_instance_profile" "splunk_enterprise" {
  count = local.splunk_enterprise_count
  name  = "${var.cluster_name}-splunk-enterprise"
  role  = aws_iam_role.splunk_enterprise[0].name
}

################################################################################
# SSH key (operator-only access, also recoverable if SSM is unavailable)
################################################################################

resource "tls_private_key" "splunk_enterprise" {
  count     = local.splunk_enterprise_count
  algorithm = "ED25519"
}

resource "aws_key_pair" "splunk_enterprise" {
  count      = local.splunk_enterprise_count
  key_name   = "${var.cluster_name}-splunk-enterprise"
  public_key = tls_private_key.splunk_enterprise[0].public_key_openssh
}

# Persist the private key locally with 0600 perms. terraform/.gitignore should
# already cover the .pem extension; verified in the gitignore audit step.
resource "local_sensitive_file" "splunk_enterprise_private_key" {
  count           = local.splunk_enterprise_count
  filename        = "${path.module}/splunk-enterprise.pem"
  content         = tls_private_key.splunk_enterprise[0].private_key_openssh
  file_permission = "0600"
}

################################################################################
# Security group
################################################################################

resource "aws_security_group" "splunk_enterprise" {
  count       = local.splunk_enterprise_count
  name        = "${var.cluster_name}-splunk-enterprise"
  description = "Splunk Enterprise demo node: web/HEC/REST/forwarder/SSH"
  vpc_id      = data.aws_vpc.default.id
}

# 8000 - Splunk Web (UI) - operator CIDRs only
resource "aws_security_group_rule" "splunk_web" {
  count             = local.splunk_enterprise_count
  type              = "ingress"
  from_port         = 8000
  to_port           = 8000
  protocol          = "tcp"
  cidr_blocks       = local.splunk_web_cidrs
  security_group_id = aws_security_group.splunk_enterprise[0].id
  description       = "Splunk Web from operator CIDRs"
}

# 8089 - Splunk REST/management - operator CIDRs only
resource "aws_security_group_rule" "splunk_rest" {
  count             = local.splunk_enterprise_count
  type              = "ingress"
  from_port         = 8089
  to_port           = 8089
  protocol          = "tcp"
  cidr_blocks       = local.splunk_web_cidrs
  security_group_id = aws_security_group.splunk_enterprise[0].id
  description       = "Splunk REST/management from operator CIDRs"
}

# 22 - SSH - operator CIDRs only (key-pair auth)
resource "aws_security_group_rule" "splunk_ssh" {
  count             = local.splunk_enterprise_count
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = local.splunk_web_cidrs
  security_group_id = aws_security_group.splunk_enterprise[0].id
  description       = "SSH from operator CIDRs"
}

# 8088 - HEC - VPC CIDR only (OTel Collector pod IPs)
resource "aws_security_group_rule" "splunk_hec" {
  count             = local.splunk_enterprise_count
  type              = "ingress"
  from_port         = 8088
  to_port           = 8088
  protocol          = "tcp"
  cidr_blocks       = [data.aws_vpc.default.cidr_block]
  security_group_id = aws_security_group.splunk_enterprise[0].id
  description       = "HEC from inside the VPC (OTel Collector)"
}

# 9997 - S2S forwarder - VPC CIDR only (Splunk forwarders inside the cluster)
resource "aws_security_group_rule" "splunk_s2s" {
  count             = local.splunk_enterprise_count
  type              = "ingress"
  from_port         = 9997
  to_port           = 9997
  protocol          = "tcp"
  cidr_blocks       = [data.aws_vpc.default.cidr_block]
  security_group_id = aws_security_group.splunk_enterprise[0].id
  description       = "Splunk-to-Splunk forwarding from inside the VPC"
}

# Egress: allow all so the instance can reach yum/dnf mirrors, AWS APIs, etc.
resource "aws_security_group_rule" "splunk_egress_all" {
  count             = local.splunk_enterprise_count
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.splunk_enterprise[0].id
  description       = "Egress to anywhere (yum, S3, AWS APIs)"
}

################################################################################
# EC2 instance
################################################################################

# Pick the first default-VPC subnet in the AZ list. EKS nodes already live
# in these subnets so the OTel Collector can route to the Splunk node over
# private addressing without crossing AZ boundaries unnecessarily.
data "aws_subnet" "splunk_enterprise" {
  count = local.splunk_enterprise_count
  id    = sort(data.aws_subnets.default.ids)[0]
}

resource "aws_instance" "splunk_enterprise" {
  count = local.splunk_enterprise_count

  ami                         = data.aws_ami.al2023[0].id
  instance_type               = var.splunk_enterprise_instance_type
  subnet_id                   = data.aws_subnet.splunk_enterprise[0].id
  vpc_security_group_ids      = [aws_security_group.splunk_enterprise[0].id]
  iam_instance_profile        = aws_iam_instance_profile.splunk_enterprise[0].name
  key_name                    = aws_key_pair.splunk_enterprise[0].key_name
  associate_public_ip_address = true
  monitoring                  = true

  # IMDSv2 only (codeguard-0-iac-security: never enable legacy IMDSv1).
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.splunk_enterprise_root_volume_gb
    encrypted             = true
    delete_on_termination = true
  }

  # gzip-compressed + base64-encoded so the rendered cloud-init payload fits
  # the EC2 16,384-byte user_data hard limit. The bootstrap + Let's Encrypt
  # wrapper scripts inlined inside the .tftpl render to ~17.9 KB raw (above
  # the limit); base64gzip drops that to ~6 KB. cloud-init detects the gzip
  # magic bytes on the instance side and decompresses transparently before
  # parsing #cloud-config.
  user_data_base64 = base64gzip(
    templatefile("${path.module}/cloud-init/splunk-enterprise.tftpl", {
      splunk_bucket             = aws_s3_bucket.splunk_media[0].id
      splunk_tarball_key        = local.splunk_tarball_key
      splunk_license_key        = local.splunk_license_key
      splunk_admin_password     = var.splunk_enterprise_admin_password
      splunk_hec_token          = var.splunk_enterprise_hec_token
      splunk_hec_token_firehose = var.splunk_enterprise_hec_token_firehose
      splunk_hec_token_scripts  = var.splunk_enterprise_hec_token_scripts

      # Let's Encrypt installer wired through cloud-init for fresh deploys.
      # The installer body lives in S3 (see null_resource.upload_splunk_media);
      # the cloud-init wrapper aws-s3-cps it down at first boot and runs it
      # with FQDN and EMAIL set. Source of truth: scripts/lib/install_letsencrypt_hec.sh.
      # We pass only the S3 location through templatefile() rather than the
      # script body itself, because base64-embedding the body pushed user_data
      # past the EC2 16,384-byte hard limit and broke `terraform plan`.
      splunk_letsencrypt_enabled = var.letsencrypt_hec_enabled
      splunk_letsencrypt_fqdn = (
        var.letsencrypt_hec_enabled
        && var.splunk_enterprise_dns_enabled
      ) ? local.splunk_enterprise_fqdn : ""
      splunk_letsencrypt_email        = var.letsencrypt_admin_email
      splunk_letsencrypt_installer_s3 = "s3://${aws_s3_bucket.splunk_media[0].id}/${local.splunk_letsencrypt_installer_key}"
    })
  )

  tags = {
    Name = "${var.cluster_name}-splunk-enterprise"
    Role = "splunk-enterprise"
  }

  # The instance bootstraps from S3 via cloud-init; ensure media is uploaded
  # first so cloud-init's aws s3 cp doesn't race the upload.
  depends_on = [null_resource.upload_splunk_media]

  lifecycle {
    # Replacing the box on every user-data tweak would re-download the 1.7 GB
    # tarball and reseed admin/license. Cloud-init is idempotent for in-place
    # changes, so we deliberately don't trigger replacement on user_data.
    # Both attribute names are listed because we historically used `user_data`
    # and switched to `user_data_base64` (gzipped) once the rendered cloud-init
    # crossed the 16,384-byte EC2 limit.
    #
    # AMI and instance_type are also ignored: data.aws_ami.al2023 resolves to
    # "latest" so a fresh AMI release would otherwise force-replace the
    # instance and tear down all of Splunk Enterprise (indexes, ITSI configs,
    # HEC tokens, license registration). Operators wanting to take a new AMI
    # should `terraform taint` the instance explicitly, accept the rebuild
    # window, and rerun the bootstrap. Same logic for instance_type changes.
    ignore_changes = [
      user_data,
      user_data_base64,
      ami,
      instance_type,
    ]
  }
}
