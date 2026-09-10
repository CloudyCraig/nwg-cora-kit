variable "region" {
  description = "AWS region for the demo. Defaults to London to match NatWest's UK footprint."
  type        = string
  default     = "eu-west-2"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "natwest-payments-demo"
}

variable "cluster_version" {
  description = "EKS Kubernetes version. Bumped to 1.33 on 2026-06-04 after AWS-side upgrades on 2026-05-28 (1.31) and 2026-05-29 (1.33); the nodegroup version tracks this variable, so keep it aligned with whatever the control plane has been moved to to avoid a terraform-driven downgrade."
  type        = string
  default     = "1.33"
}

variable "owner" {
  description = "Tag applied to all resources for cost tracking / ownership."
  type        = string
  default     = "splunk-demo"
}

variable "splunkit_environment_type" {
  description = "Value for the Splunk-mandated 'splunkit_environment_type' tag. Must match the org tag policy: one of prd, customer-prd, non-prd, customer-non-prd."
  type        = string
  default     = "non-prd"

  validation {
    condition     = contains(["prd", "customer-prd", "non-prd", "customer-non-prd"], var.splunkit_environment_type)
    error_message = "splunkit_environment_type must be one of: prd, customer-prd, non-prd, customer-non-prd (enforced by the org tag policy)."
  }
}

variable "splunkit_data_classification" {
  description = "Value for the Splunk-mandated 'splunkit_data_classification' tag. Must match the org tag policy: one of public, private, confidential, highly-confidential."
  type        = string
  default     = "public"

  validation {
    condition     = contains(["public", "private", "confidential", "highly-confidential"], var.splunkit_data_classification)
    error_message = "splunkit_data_classification must be one of: public, private, confidential, highly-confidential (enforced by the org tag policy)."
  }
}

# Cross-resource grouping tag applied to every AWS resource via the
# provider's default_tags block (see versions.tf). Lets Cost Explorer,
# AWS Resource Groups, and the SOC Slack #demo-fleet bot identify all
# resources belonging to this specific customer demo. Override with
# TF_VAR_splunk_demo=<slug> when forking the stack for a different
# customer scenario - the rest of the topology is generic.
#
# Tag-key constraint: AWS tag keys are case-sensitive, must be 1-128
# chars, allow alphanumerics + space + the punctuation set _.:/=+-@ ,
# and must not start with `aws:`. We additionally restrict the *value*
# to an alphanumeric slug (mixed-case allowed so customer brand
# capitalisation can be preserved, e.g. "Natwest", "Cisco") so it's
# safe in Resource Group queries and Cost-Explorer filter URLs. Tag
# values are case-sensitive in the AWS API but most consoles surface
# them case-insensitively in filter pickers.
variable "splunk_demo" {
  description = "Value for the cross-resource 'splunk-demo' grouping tag. Identifies which customer demo a resource belongs to."
  type        = string
  default     = "Natwest"

  validation {
    condition     = can(regex("^[A-Za-z0-9]([A-Za-z0-9-]{0,62}[A-Za-z0-9])?$", var.splunk_demo))
    error_message = "splunk_demo must be an alphanumeric slug (1-64 chars, [A-Za-z0-9-], no leading/trailing dash)."
  }
}

variable "allowed_public_api_cidrs" {
  description = <<EOT
CIDR blocks allowed to reach the EKS public API endpoint.
REQUIRED: restrict this to your operator IPs. Never leave 0.0.0.0/0.
Example: ["203.0.113.4/32"].
EOT
  type        = list(string)

  validation {
    condition     = length(var.allowed_public_api_cidrs) > 0 && !contains(var.allowed_public_api_cidrs, "0.0.0.0/0")
    error_message = "allowed_public_api_cidrs must be a non-empty list and must not include 0.0.0.0/0. Restrict access to operator IPs."
  }
}

variable "node_instance_types" {
  description = "Managed node group instance types."
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_desired_size" {
  description = "Desired managed node group size."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum managed node group size."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum managed node group size."
  type        = number
  default     = 4
}

variable "splunk_realm" {
  description = "Splunk Observability Cloud realm (e.g. us0, us1, eu0)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{2,10}$", var.splunk_realm))
    error_message = "splunk_realm must look like us0, us1, eu0, ap0, etc."
  }
}

variable "splunk_access_token" {
  description = "Splunk Observability Cloud access (ingest) token. Passed via TF_VAR_splunk_access_token - never committed."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.splunk_access_token) >= 16
    error_message = "splunk_access_token must be provided and non-trivial."
  }
}

variable "splunk_api_token" {
  description = <<EOT
Splunk Observability Cloud user-level API token (NOT the ingest access
token). Required for the signalfx provider to manage detectors,
dashboards, and synthetic checks. Pass via TF_VAR_splunk_api_token; do
not commit. Set to an empty string to skip provisioning observability
config (provider will be defined but no SignalFx resources created).
EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "splunk_observability_enabled" {
  description = <<EOT
Master switch for the SignalFx-managed observability config (detectors,
dashboards, synthetic checks). Defaults to false because most demo
environments are bootstrapped without an API token; flip to true once
TF_VAR_splunk_api_token is in place.
EOT
  type        = bool
  default     = false
}

variable "splunk_synthetics_enabled" {
  description = <<EOT
Provision Splunk Synthetics tests (payments API + optional SPA /healthz API +
optional SPA browser) via the v2 REST API. Requires var.splunk_api_token.
Gated on its own variable so an operator running terraform apply doesn't
accidentally start charging the org for synthetic device-minutes.

The payments API check exercises /api/v1/payments/process; the SPA health
check GETs /healthz; the browser check loads the SPA login page. Enabled
checks feed kbs_synthetic_success in itsi/service-tree.yaml for the L2
Customer Channel KPI when LOC forwards synthetic_run events.
EOT
  type        = bool
  default     = false
}

variable "splunk_synthetic_target_url" {
  description = <<EOT
Public URL of the api-gateway endpoint (e.g.
https://itsi.splunk-observability.com/api/v1/payments/process) used by
the Splunk Synthetics API check provisioned by null_resource.
splunk_synthetic_api_check when var.splunk_synthetics_enabled = true.
Leave blank to disable the API check even if synthetics are enabled.
EOT
  type        = string
  default     = ""
}

variable "splunk_synthetic_browser_url" {
  description = <<EOT
Public URL of the SPA login page (e.g.
https://itsi.splunk-observability.com/login) loaded by the Splunk
Synthetics browser check provisioned by null_resource.
splunk_synthetic_browser_check when var.splunk_synthetics_enabled =
true. Leave blank to disable the browser check.
EOT
  type        = string
  default     = ""
}

variable "splunk_synthetic_spa_health_url" {
  description = <<EOT
Public URL for the Splunk Synthetics API check that GETs the SPA nginx
/healthz endpoint (HTTP 200, body contains "ok"). Example:
https://itsi.splunk-observability.com/healthz — must match the web-frontend
probe path (see frontend/nginx/default.conf.template). Provisioned by
null_resource.splunk_synthetic_spa_health_check when
var.splunk_synthetics_enabled = true. Leave blank to skip this check.
EOT
  type        = string
  default     = ""
}

variable "splunk_synthetic_proxy_health_url" {
  description = <<EOT
Public URL for the Splunk Synthetics API check that GETs the *public
nginx proxy*'s health endpoint at /__proxy_health (HTTP 200, body
contains "ok"). This sits in front of the upstream web-frontend and
exercises *only* the proxy layer on the Splunk Enterprise EC2 — so a
healthy /healthz with a failing /__proxy_health pinpoints an upstream
NodePort issue, and the reverse pinpoints nginx itself.

Pair with the on-host systemd watchdog installed by
scripts/05b-frontend-public-proxy.sh: the watchdog catches and self-
heals fast failures on the box; this synthetic catches *systemic*
failures (EIP loss, SG drift, AZ outage) that the watchdog can't see
from inside the same VM. Page on this one, not on /healthz.

Provisioned by null_resource.splunk_synthetic_proxy_health_check when
var.splunk_synthetics_enabled = true. Leave blank to skip.
EOT
  type        = string
  default     = ""
}

variable "splunk_synthetic_locations" {
  description = <<EOT
JSON array of Splunk Synthetics location IDs (devices) for the
provisioned tests. Defaults to a single AWS-EU location to match the
demo's London footprint. List available IDs with:
  curl -H "X-SF-TOKEN: $TOKEN" https://api.<realm>.signalfx.com/v2/synthetics/devices
EOT
  type        = string
  default     = "[\"aws-eu-west-1\"]"
}

variable "splunk_alert_recipients" {
  description = <<EOT
Email addresses notified when SignalFx detectors fire. Empty list keeps
alerts silent (still visible in the UI). Each entry becomes an email
notification on Critical and Warning rules.
EOT
  type        = list(string)
  default     = []
}

################################################################################
# Splunk Enterprise (single-node, in-VPC) - powers Log Observer Connect so
# logs land in Splunk Observability via the Splunk Platform stack instead of
# the otherwise-unreachable o11y /v1/log endpoint.
################################################################################

variable "splunk_enterprise_enabled" {
  description = "Provision a single-node Splunk Enterprise EC2 instance in the demo VPC."
  type        = bool
  default     = true
}

variable "splunk_enterprise_admin_password" {
  description = <<EOT
Splunk Enterprise admin bootstrap password. Demo-only credential -
override via TF_VAR_splunk_enterprise_admin_password for any non-demo
deployment. Stored only in cloud-init (rendered into instance user-data,
not state) and in /opt/splunk/etc/passwd on the instance after first
boot. Minimum 8 characters per Splunk's policy.
EOT
  type        = string
  default     = "smartway"
  sensitive   = true

  validation {
    condition     = length(var.splunk_enterprise_admin_password) >= 8
    error_message = "splunk_enterprise_admin_password must be at least 8 characters (Splunk requirement)."
  }
}

variable "splunk_enterprise_instance_type" {
  description = "EC2 instance type for the Splunk Enterprise node. c5a.8xlarge (32 vCPU / 64 GB) fits ITSI + single-node ingest/search load; resize live with scripts/resize-splunk-enterprise-ec2.sh (Terraform ignores instance_type to avoid replacement)."
  type        = string
  default     = "c5a.8xlarge"
}

variable "splunk_enterprise_root_volume_gb" {
  description = "Root EBS volume size in GB. Splunk media + license + warm bucket headroom."
  type        = number
  default     = 500
}

variable "splunk_enterprise_media_path" {
  description = "Absolute path to the Splunk Enterprise installer .tgz on the operator's machine. Uploaded to the staging S3 bucket on apply."
  type        = string
  # OneDrive-synced operator media folder. Override with
  # TF_VAR_splunk_enterprise_media_path if you keep the tarball
  # elsewhere - the path is operator-specific and not portable.
  default = "/Users/mserieys/Library/CloudStorage/OneDrive-Cisco/_Cursor/_media+license+logins/splunk-10.2.2-80b90d638de6-linux-amd64.tgz"
}

variable "splunk_enterprise_license_path" {
  description = "Absolute path to the Splunk Enterprise NFR license file. Uploaded to S3 alongside the media."
  type        = string
  default     = "/Users/mserieys/Library/CloudStorage/OneDrive-Cisco/_Cursor/_media+license+logins/Splunk Enterprise NFR CY2026.License"
}

# ----------------------------------------------------------------------------
# Splunk Enterprise HEC tokens.
#
# Required inputs, no defaults. Earlier versions of this file shipped three
# UUID-shaped "placeholder" defaults committed to git; that breached the
# no-hardcoded-credentials policy because anyone with the repo URL had the
# actual live HEC tokens for any environment that had been applied without
# an override. The defaults have been removed in commit
# "terraform: remove hardcoded HEC token defaults"; operators must now
# supply each token via TF_VAR_* or a tfvars file.
#
# Generate fresh values with `uuidgen` (one per variable). For an existing
# deployment that was applied against the old defaults, capture the live
# value with `terraform -chdir=terraform output -raw <token>` (the state
# still has it) then rotate to a fresh UUID and re-run
# scripts/00b-update-splunk-config.sh to push the new value to splunkd.
# ----------------------------------------------------------------------------

variable "splunk_enterprise_hec_token" {
  description = <<EOT
Pre-shared HEC token for the OTel Collector and any other in-VPC log
shippers. Pinned in cloud-init so the collector's splunkPlatform.token
is known up-front (no terraform output -> kubectl secret round-trip).
This is a UUIDv4 by convention but any 36+ character string works.

Allow-listed indexes (as set in cloud-init):
  main, _internal, itsi_im_metrics, nwpay_audit, nwpay_infra

Required. Set via TF_VAR_splunk_enterprise_hec_token. Generate with `uuidgen`.
EOT
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.splunk_enterprise_hec_token) >= 36
    error_message = "splunk_enterprise_hec_token must be at least 36 characters (a UUID is fine). Generate with `uuidgen`."
  }
}

variable "splunk_enterprise_hec_token_firehose" {
  description = <<EOT
HEC token used by Kinesis Firehose delivery streams to push AWS cloud
plane logs (CloudTrail, VPC Flow, GuardDuty, EKS audit) into Splunk
Enterprise. Distinct from the OTel collector token so the ingest source
is identifiable in metrics.log and the index allow-list can be tightly
scoped to AWS log indexes only.

Allow-listed indexes: aws_cloudtrail, aws_vpcflow, aws_guardduty,
aws_eks_audit.

Required. Set via TF_VAR_splunk_enterprise_hec_token_firehose. Generate with `uuidgen`.
EOT
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.splunk_enterprise_hec_token_firehose) >= 36
    error_message = "splunk_enterprise_hec_token_firehose must be at least 36 characters (a UUID is fine). Generate with `uuidgen`."
  }
}

variable "splunk_enterprise_hec_token_scripts" {
  description = <<EOT
HEC token used by demo helper scripts (chaos audit, banking-event
synthesis on the operator side) to write into the audit index without
having access to the broader allow-list of the OTel collector token.

Allow-listed indexes: nwpay_audit only.

Required. Set via TF_VAR_splunk_enterprise_hec_token_scripts. Generate with `uuidgen`.
EOT
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.splunk_enterprise_hec_token_scripts) >= 36
    error_message = "splunk_enterprise_hec_token_scripts must be at least 36 characters (a UUID is fine). Generate with `uuidgen`."
  }
}

variable "splunk_enterprise_web_allowed_cidrs" {
  description = <<EOT
CIDR blocks allowed to reach Splunk Web (TCP 8000) and the management
port (TCP 8089) on the Splunk Enterprise instance from outside the VPC.
Defaults to the same operator CIDRs that talk to the EKS API. NEVER
0.0.0.0/0.
EOT
  type        = list(string)
  default     = null
}
