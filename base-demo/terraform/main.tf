data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  ecr_repos = [
    "natwest-payments-service",
    "natwest-payments-traffic-generator",
    "natwest-payments-ledger-service-java",
    "natwest-payments-web-frontend",
    "natwest-payments-chaos-controller",
  ]
}

################################################################################
# Default VPC lookup
#
# The AWS Organization SCP on this account denies ec2:CreateVpc (and related
# networking create actions), so we reuse the default VPC and its subnets
# instead of provisioning a fresh VPC. EKS is deployed into the existing
# default-VPC public subnets. Nodes are given public IPs (default VPC maps
# public IP on launch) and the control plane endpoint is locked down to
# var.allowed_public_api_cidrs for API access.
#
# If the SCP is lifted later, revert to the terraform-aws-modules/vpc/aws
# module for proper isolated private/public subnets + NAT.
################################################################################

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# Tag default-VPC subnets so the AWS Load Balancer Controller / EKS can use
# them for internet-facing load balancers. aws_ec2_tag only adds a tag; it does
# not overwrite other tags on the resource, and the tag is removed on destroy.
resource "aws_ec2_tag" "subnet_elb_role" {
  for_each    = toset(data.aws_subnets.default.ids)
  resource_id = each.value
  key         = "kubernetes.io/role/elb"
  value       = "1"
}

################################################################################
# KMS key for EKS secrets envelope encryption
################################################################################

resource "aws_kms_key" "eks" {
  description             = "KMS key for EKS secrets envelope encryption (${var.cluster_name})"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.cluster_name}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

################################################################################
# EKS
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = data.aws_vpc.default.id
  subnet_ids = data.aws_subnets.default.ids

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.allowed_public_api_cidrs
  cluster_endpoint_private_access      = true

  cluster_enabled_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]

  cluster_encryption_config = {
    provider_key_arn = aws_kms_key.eks.arn
    resources        = ["secrets"]
  }

  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
  }

  eks_managed_node_groups = {
    demo = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types

      min_size     = var.node_min_size
      desired_size = var.node_desired_size
      max_size     = var.node_max_size

      # Default-VPC subnets are public. Give the nodes public IPs so they can
      # pull from ECR and register with EKS without a NAT gateway.
      subnet_ids = data.aws_subnets.default.ids

      disk_size = 30

      labels = {
        workload = "natwest-payments-demo"
      }

      # Explicitly set Splunk mandatory tags on the instance itself (via the
      # launch template tag_specifications) so ec2:RunInstances passes the
      # corporate SCP that requires these request-time tags. splunk-demo is
      # also pinned here (in addition to the provider default_tags block in
      # versions.tf) so the cross-resource grouping tag is guaranteed to be
      # applied at instance/EBS/ENI creation time rather than relying on the
      # EKS module to merge default_tags into the launch template's
      # tag_specifications, which has historically been version-dependent.
      tags = {
        splunkit_environment_type    = var.splunkit_environment_type
        splunkit_data_classification = var.splunkit_data_classification
        splunk-demo                  = var.splunk_demo
      }
    }
  }

  depends_on = [aws_ec2_tag.subnet_elb_role]
}

################################################################################
# ECR repositories (image scan on push, immutable tags)
################################################################################

resource "aws_ecr_repository" "app" {
  for_each = toset(local.ecr_repos)

  name                 = each.value
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

################################################################################
# Splunk Observability access token stored in AWS Secrets Manager
# (consumed by the OTel Collector via External Secrets or a K8s Secret synced
#  via kubectl - see scripts/02-install-collector.sh).
################################################################################

resource "aws_secretsmanager_secret" "splunk_token" {
  name                    = "${var.cluster_name}/splunk-observability-token"
  description             = "Splunk Observability Cloud ingest token for the NatWest payments demo"
  kms_key_id              = aws_kms_key.eks.arn
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "splunk_token" {
  secret_id = aws_secretsmanager_secret.splunk_token.id
  # token_name is populated by the rotation Lambda on each rotation cycle.
  # The seed value is empty on bootstrap, which the Lambda's `_finish_secret`
  # tolerates (it skips the SO Cloud DELETE for an unknown previous name).
  # See scripts/lib/lambda/rotate_splunk_ingest_token.py.
  secret_string = jsonencode({
    realm      = var.splunk_realm
    token      = var.splunk_access_token
    token_name = ""
  })

  # Once the rotation Lambda starts cycling this secret, the value held in
  # AWS will differ from what terraform thinks it knows. ignore_changes
  # prevents a subsequent `terraform apply` from clobbering the rotated
  # value with the original `var.splunk_access_token`.
  lifecycle {
    ignore_changes = [secret_string]
  }
}
