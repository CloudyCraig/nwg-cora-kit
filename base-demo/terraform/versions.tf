terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    signalfx = {
      source  = "splunk-terraform/signalfx"
      version = "~> 9.6"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# Splunk Observability provider. Manages detectors, dashboards and
# synthetic checks. The user-API-token (separate from the ingest access
# token) is passed via TF_VAR_splunk_api_token and never committed.
#
# When splunk_observability_enabled is false (the default), no signalfx
# resources are created, but the provider still has to be configured -
# we feed it a non-empty placeholder so terraform plan/apply doesn't
# fail before even reaching the resource graph.
provider "signalfx" {
  auth_token = length(var.splunk_api_token) > 0 ? var.splunk_api_token : "disabled-placeholder"
  api_url    = "https://api.${var.splunk_realm}.signalfx.com"
}

provider "aws" {
  region = var.region

  # default_tags propagate to every taggable AWS resource created by this
  # provider (EKS, ECR, IAM, VPC, EC2, EBS, ALB, KMS, Secrets Manager, S3,
  # Firehose, CloudWatch log groups, etc.). Per-resource `tags = { ... }`
  # blocks are *merged* with these, not replacing them, so adding a key here
  # is the single point of truth for cross-resource tagging.
  default_tags {
    tags = {
      Project     = "natwest-payments-demo"
      Environment = "demo"
      ManagedBy   = "terraform"
      Owner       = var.owner
      # Required by Splunk corporate SCPs (DenyCreationEnvironmentTag /
      # DenyCreationDataClassificationTag). Without these the SCP blocks
      # RunInstances, CreateDBInstance, CreateLoadBalancer, etc.
      splunkit_environment_type    = var.splunkit_environment_type
      splunkit_data_classification = var.splunkit_data_classification
      # Splunk demo-fleet grouping tag. Lets the AWS console / Cost Explorer
      # / Resource Groups filter every resource belonging to this customer
      # demo (overridable via TF_VAR_splunk_demo if the same stack is ever
      # forked for another customer scenario).
      splunk-demo = var.splunk_demo
    }
  }
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
