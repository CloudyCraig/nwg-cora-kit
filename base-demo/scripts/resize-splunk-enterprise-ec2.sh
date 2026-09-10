#!/usr/bin/env bash
# Resize the Splunk Enterprise EC2 instance (Terraform: aws_instance.splunk_enterprise).
# AWS requires: STOP -> ModifyInstanceAttribute (instance type) -> START.
#
# Prerequisites:
#   * aws CLI v2 (or v1) with credentials for profile **cursor-admin** (default).
#     Configure once:  aws configure --profile cursor-admin
#     (or SSO / env vars; override profile with AWS_PROFILE=...).
#   * Same account/region as the instance (default region: eu-west-2).
#
# Usage:
#   ./scripts/resize-splunk-enterprise-ec2.sh
#   SPLUNK_EC2_INSTANCE_ID=i-xxxxx TARGET_INSTANCE_TYPE=c5a.8xlarge ./scripts/resize-splunk-enterprise-ec2.sh
#
# After this completes, run from terraform/:
#   terraform refresh
#   terraform plan   # should show no drift if splunk_enterprise_instance_type matches

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_cmd aws

# IAM user `cursor-admin` in the demo account (KMS/TF state references this principal).
export AWS_PROFILE="${AWS_PROFILE:-cursor-admin}"

AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-west-2}}"
export AWS_DEFAULT_REGION="${AWS_REGION}"

TARGET_INSTANCE_TYPE="${TARGET_INSTANCE_TYPE:-c5a.8xlarge}"

if [[ -n "${SPLUNK_EC2_INSTANCE_ID:-}" ]]; then
  INSTANCE_ID="${SPLUNK_EC2_INSTANCE_ID}"
elif [[ -n "${1:-}" ]]; then
  INSTANCE_ID="$1"
else
  if command -v terraform >/dev/null 2>&1; then
    INSTANCE_ID="$(terraform -chdir="${TERRAFORM_DIR}" output -raw splunk_enterprise_instance_id 2>/dev/null || true)"
  fi
  [[ -n "${INSTANCE_ID}" ]] || fail "Set SPLUNK_EC2_INSTANCE_ID or pass instance id as arg #1 (terraform output unavailable)"
fi

log "AWS identity:"
aws sts get-caller-identity

CUR="$(aws ec2 describe-instances \
  --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].[InstanceType,State.Name]' \
  --output text)"
READ_TYPE="$(echo "${CUR}" | awk '{print $1}')"
READ_STATE="$(echo "${CUR}" | awk '{print $2}')"

log "instance ${INSTANCE_ID}: type=${READ_TYPE} state=${READ_STATE}"

if [[ "${READ_TYPE}" == "${TARGET_INSTANCE_TYPE}" ]]; then
  log "already ${TARGET_INSTANCE_TYPE}; nothing to do"
  exit 0
fi

if [[ "${READ_STATE}" == "running" ]]; then
  log "stopping ${INSTANCE_ID} (Splunk will be down until start completes)"
  aws ec2 stop-instances --instance-ids "${INSTANCE_ID}" >/dev/null
fi

log "waiting for stopped..."
aws ec2 wait instance-stopped --instance-ids "${INSTANCE_ID}"

log "setting instance type -> ${TARGET_INSTANCE_TYPE}"
aws ec2 modify-instance-attribute \
  --instance-id "${INSTANCE_ID}" \
  --instance-type "Value=${TARGET_INSTANCE_TYPE}"

log "starting ${INSTANCE_ID}"
aws ec2 start-instances --instance-ids "${INSTANCE_ID}" >/dev/null

log "waiting for running..."
aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}"

VERIFY="$(aws ec2 describe-instances \
  --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].InstanceType' \
  --output text)"
log "resize complete: ${INSTANCE_ID} is ${VERIFY} (state running)"
