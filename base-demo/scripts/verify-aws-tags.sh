#!/usr/bin/env bash
# scripts/verify-aws-tags.sh
#
# Audit every taggable AWS resource in the configured region for the
# cross-resource grouping tag `splunk-demo=<value>` (default `Natwest`).
#
# Why this exists:
#   The Terraform provider's `default_tags` block (terraform/versions.tf)
#   stamps `splunk-demo = var.splunk_demo` onto every taggable AWS
#   resource it creates. AWS Cost Explorer / Resource Groups / the SOC
#   demo-fleet bot all key off that tag to identify resources belonging
#   to a specific customer demo. This script is a read-only audit that
#   confirms reality matches that intent: it lists *every* in-region
#   resource missing the tag and *every* resource where the tag value
#   diverges from the expected slug.
#
#   Useful in two situations:
#     1. After `terraform apply`, to confirm the run actually pushed the
#        tag to every resource (catches launch-template/tag-specifications
#        propagation bugs the way the EKS module has historically had).
#     2. Whenever the AWS account is shared with non-Terraform-owned
#        resources (manual EC2s, console-clicked S3 buckets) - the tag
#        will be absent and the script flags them so they can be tagged
#        retroactively or removed.
#
# Usage:
#   scripts/verify-aws-tags.sh                            # default: splunk-demo=Natwest in eu-west-2
#   scripts/verify-aws-tags.sh --value MyDemo             # different demo slug
#   scripts/verify-aws-tags.sh --region us-east-1         # different region
#   scripts/verify-aws-tags.sh --json                     # machine-readable output
#   scripts/verify-aws-tags.sh --fix                      # add the tag in-place to every untagged resource
#   scripts/verify-aws-tags.sh --strict                   # also fail on resources whose splunk-demo value is different
#
# By default the script ignores resources that already carry a *different*
# splunk-demo value: they belong to a separate Splunk demo deployment in
# the same account (e.g. the splunk-demo-controller CloudFormation stack
# this repo's NatWest demo coexists with). Pass --strict to flag them too.
#
# Exit codes:
#   0  - every taggable resource has the expected tag (or a different splunk-demo value, in non-strict mode)
#   1  - one or more resources missing the tag (details printed)
#   2  - missing dependency / invalid invocation
#
# Notes:
#   * Read-only by default. `--fix` is destructive in the sense that it
#     mutates tags on existing resources; review the dry-run output first.
#   * The Resource Groups Tagging API does NOT enumerate every taggable
#     service - notably it omits IAM roles/policies and a handful of
#     account-scoped resources. We supplement the call with explicit
#     iam:ListRoles + iam:ListRoleTags so the natwest-payments-* roles
#     created by Terraform are covered too.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

require_cmd aws jq

# Defaults align with terraform/variables.tf (var.splunk_demo, var.region,
# var.cluster_name).
TAG_KEY="splunk-demo"
TAG_VALUE="${SPLUNK_DEMO:-Natwest}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-west-2}}"
CLUSTER_NAME="${CLUSTER_NAME:-natwest-payments-demo}"
JSON=0
FIX=0
STRICT=0
# Filter the IAM-role audit to roles that look like they belong to this
# demo. IAM is global (not regional), so without a name filter the audit
# would flag every role in the account, including unrelated ones.
IAM_ROLE_NAME_PREFIX="${IAM_ROLE_NAME_PREFIX:-natwest-payments}"

# Resource ARN substrings (or AWS-tag matches) that identify resources
# belonging to *this* NatWest demo. We use these to filter the result of
# resourcegroupstaggingapi:GetResources so the audit reports only on
# demo-owned assets, not on AWS-account-wide infrastructure (Control
# Tower stacks, Splunk org config rules, default-VPC subnets, etc.) or
# unrelated demo instances co-tenant in the same AWS account.
#
# Coverage rationale:
#   * "natwest-payments-"  - all Terraform-named resources (cluster,
#                            ECR repos, SGs, IAM roles, KMS aliases).
#   * "nwpay-"             - shorter prefix used for some Firehose /
#                            CloudTrail / S3 backup names that hit AWS
#                            length limits.
#   * "${CLUSTER_NAME}/"   - sub-resource ARNs like ECR pods or EKS
#                            objects scoped to the cluster name.
#   * tag eks:cluster-name=${CLUSTER_NAME}
#                          - EKS-launched EC2 instances, EBS volumes,
#                            and primary ENIs always carry this tag.
#   * tag Project=natwest-payments-demo
#                          - belt-and-braces: any resource that already
#                            carries the Project tag from default_tags.
NATWEST_NAME_SUBSTRINGS=( "natwest-payments-" "nwpay-" "${CLUSTER_NAME}" )
NATWEST_TAG_MATCHES=(
  # EKS-launched primary ENIs and managed-node-group resources.
  "eks:cluster-name=${CLUSTER_NAME}"
  # VPC CNI agent-created secondary ENIs for pod IPs.
  "cluster.k8s.amazonaws.com/name=${CLUSTER_NAME}"
  # Belt-and-braces: any resource that already carries the Project tag
  # from the provider default_tags block in versions.tf.
  "Project=natwest-payments-demo"
)

# ARN-prefix exclusions. The Resource Groups Tagging API enumerates
# transient EKS pod records (one per pod scheduling cycle). They are
# not meaningful "AWS assets" the operator manages directly and would
# otherwise dominate the audit output, so we filter them out before
# reporting. Adjust if you need to audit them.
NATWEST_ARN_EXCLUDES=( ":pod/" )

for arg in "$@"; do
  case "${arg}" in
    --json)             JSON=1 ;;
    --fix)              FIX=1 ;;
    --strict)           STRICT=1 ;;
    --value)            shift; TAG_VALUE="${1:-}";   shift || true ;;
    --value=*)          TAG_VALUE="${arg#*=}" ;;
    --region)           shift; REGION="${1:-}";      shift || true ;;
    --region=*)         REGION="${arg#*=}" ;;
    --iam-prefix)       shift; IAM_ROLE_NAME_PREFIX="${1:-}"; shift || true ;;
    --iam-prefix=*)     IAM_ROLE_NAME_PREFIX="${arg#*=}" ;;
    -h|--help)
      sed -n '1,40p' "$0"; exit 0 ;;
    *) ;;
  esac
done

if [[ -z "${TAG_VALUE}" ]]; then
  fail "tag value must be non-empty (got --value '')"
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Walk Resource Groups Tagging API pages and print one ARN per line for
# every resource whose tags do NOT contain (splunk-demo=$TAG_VALUE).
# Resources that don't look like they belong to this NatWest demo (by
# ARN substring or distinguishing tag) are filtered out so the audit
# does not pollute output with org/Control-Tower/cohabitating-demo
# resources.
list_missing_or_wrong() {
  local pagination_token=""
  local response

  # Build the jq filters once. Substring match against the ARN, plus an
  # OR-set of "Key=Value" tag matches for resources whose ARN doesn't
  # carry the demo's name (EBS volumes, ENIs created by VPC CNI, etc.).
  local arn_substrings_json tag_matches_json arn_excludes_json
  arn_substrings_json="$(printf '%s\n' "${NATWEST_NAME_SUBSTRINGS[@]}" \
    | jq -R . | jq -s .)"
  tag_matches_json="$(printf '%s\n' "${NATWEST_TAG_MATCHES[@]}" \
    | jq -R 'split("=") | {Key: .[0], Value: .[1]}' | jq -s .)"
  arn_excludes_json="$(printf '%s\n' "${NATWEST_ARN_EXCLUDES[@]}" \
    | jq -R . | jq -s .)"

  while :; do
    if [[ -z "${pagination_token}" ]]; then
      response="$(aws resourcegroupstaggingapi get-resources \
        --region "${REGION}" \
        --resources-per-page 100 \
        --output json)"
    else
      response="$(aws resourcegroupstaggingapi get-resources \
        --region "${REGION}" \
        --resources-per-page 100 \
        --pagination-token "${pagination_token}" \
        --output json)"
    fi

    # Emit ARN<TAB>found_value (or empty) for any resource where the tag
    # is missing or its value differs from the expected slug.
    #
    # The intermediate `[ ... ] | first // null` form is deliberate: the
    # naive `as $found` over an empty stream silently drops the whole
    # downstream pipeline, hiding resources that lack the tag entirely.
    # We materialize the matches into an array first so missing-tag
    # resources surface as ($found == null) and reach the `select`.
    #
    # The `select(belongs_to_demo)` step drops anything that doesn't
    # carry one of the NatWest demo identifiers (ARN substring or
    # distinguishing tag), so we don't pollute output with
    # account-global / Control-Tower / co-tenant-demo resources.
    echo "${response}" | jq -r \
      --arg key "${TAG_KEY}" \
      --arg expected "${TAG_VALUE}" \
      --argjson name_substrings "${arn_substrings_json}" \
      --argjson tag_matches "${tag_matches_json}" \
      --argjson arn_excludes "${arn_excludes_json}" \
      '
        def belongs_to_demo:
          . as $r
          | ($r.Tags // []) as $tags
          | (
              # Match by ARN substring.
              ([ $name_substrings[] | select(. as $s | $r.ResourceARN | contains($s)) ] | length > 0)
              # Or by distinguishing tag value.
              or
              ([ $tag_matches[] as $m
                 | $tags[]
                 | select(.Key == $m.Key and .Value == $m.Value)
               ] | length > 0)
            );

        def excluded:
          . as $r
          | ([ $arn_excludes[] | select(. as $s | $r.ResourceARN | contains($s)) ] | length > 0);

        .ResourceTagMappingList[]
        | select(belongs_to_demo)
        | select(excluded | not)
        | . as $r
        | ($r.Tags // []) as $tags
        | ([ $tags[] | select(.Key == $key) | .Value ] | first // null) as $found
        | select($found != $expected)
        | "\($r.ResourceARN)\t\($found // "")"
      '

    pagination_token="$(echo "${response}" | jq -r '.PaginationToken // ""')"
    [[ -z "${pagination_token}" ]] && break
  done
}

# IAM is global (no region) and not enumerated by resourcegroupstaggingapi
# in every region's response, so we audit the natwest-payments-* roles
# Terraform created here explicitly.
list_missing_iam_roles() {
  local roles role tags found

  roles="$(aws iam list-roles \
    --output json \
    | jq -r --arg prefix "${IAM_ROLE_NAME_PREFIX}" \
        '.Roles[] | select(.RoleName | startswith($prefix)) | .Arn + "\t" + .RoleName')"

  [[ -z "${roles}" ]] && return 0

  while IFS=$'\t' read -r arn role; do
    [[ -z "${arn}" ]] && continue
    tags="$(aws iam list-role-tags --role-name "${role}" --output json 2>/dev/null || echo '{"Tags":[]}')"
    found="$(echo "${tags}" | jq -r --arg key "${TAG_KEY}" \
      '(.Tags[]? | select(.Key == $key) | .Value) // ""')"
    if [[ "${found}" != "${TAG_VALUE}" ]]; then
      printf '%s\t%s\n' "${arn}" "${found}"
    fi
  done <<< "${roles}"
}

# Apply (splunk-demo=$TAG_VALUE) to every ARN passed on stdin via the
# Resource Groups Tagging API. IAM role ARNs are routed through iam:TagRole
# instead because the tagging API does not cover IAM in every region.
fix_arns() {
  local arn rest role
  while IFS=$'\t' read -r arn rest; do
    [[ -z "${arn}" ]] && continue
    if [[ "${arn}" == arn:aws:iam::*:role/* ]]; then
      role="${arn##*/}"
      log "tagging IAM role: ${role}"
      aws iam tag-role \
        --role-name "${role}" \
        --tags "Key=${TAG_KEY},Value=${TAG_VALUE}" >/dev/null
    else
      log "tagging: ${arn}"
      aws resourcegroupstaggingapi tag-resources \
        --region "${REGION}" \
        --resource-arn-list "${arn}" \
        --tags "${TAG_KEY}=${TAG_VALUE}" \
        --output json >/dev/null
    fi
  done
}

# ---------------------------------------------------------------------------
# Run audit
# ---------------------------------------------------------------------------

if [[ "${JSON}" -ne 1 ]]; then
  log "auditing region=${REGION} for tag ${TAG_KEY}=${TAG_VALUE}"
fi

# Collect both missing/wrong sets into one tab-separated table.
MISSING="$( { list_missing_or_wrong; list_missing_iam_roles; } )"

MISSING_LIST="$(echo "${MISSING}" | awk -F'\t' '$2 == "" {print $1}')"
WRONG_LIST="$(echo "${MISSING}"   | awk -F'\t' '$2 != "" {print $1 "\t" $2}')"

# In non-strict mode, "wrong value" is informational (likely a different
# splunk-demo deployment sharing the same AWS account). Only resources
# that are entirely missing the tag count as audit failures.
if [[ "${STRICT}" -eq 1 ]]; then
  FAIL_LIST="${MISSING}"
else
  FAIL_LIST="${MISSING_LIST}"
fi

if [[ -z "${FAIL_LIST}" ]]; then
  if [[ "${JSON}" -eq 1 ]]; then
    jq -n \
      --arg region "${REGION}" \
      --arg key "${TAG_KEY}" \
      --arg value "${TAG_VALUE}" \
      --arg wrong "${WRONG_LIST}" \
      --argjson strict "${STRICT}" \
      '{
        region:    $region,
        tag_key:   $key,
        tag_value: $value,
        strict:    ($strict == 1),
        missing:   [],
        other_demos: (
          $wrong
          | split("\n")
          | map(select(length > 0))
          | map(split("\t") | {arn: .[0], found_value: .[1]})
        ),
        total: 0
      }'
  else
    log "OK - every NatWest demo resource carries ${TAG_KEY}=${TAG_VALUE}"
    if [[ -n "${WRONG_LIST}" ]]; then
      log "(${TAG_KEY} value differs on $(echo "${WRONG_LIST}" | wc -l | tr -d ' ') resource(s) belonging to a different demo - ignored without --strict)"
    fi
  fi
  exit 0
fi

if [[ "${JSON}" -eq 1 ]]; then
  jq -n \
    --arg region "${REGION}" \
    --arg key "${TAG_KEY}" \
    --arg value "${TAG_VALUE}" \
    --arg missing "${MISSING_LIST}" \
    --arg wrong "${WRONG_LIST}" \
    --argjson strict "${STRICT}" \
    '{
      region:    $region,
      tag_key:   $key,
      tag_value: $value,
      strict:    ($strict == 1),
      missing:   ($missing | split("\n") | map(select(length > 0))),
      other_demos: (
        $wrong
        | split("\n")
        | map(select(length > 0))
        | map(split("\t") | {arn: .[0], found_value: .[1]})
      )
    }
    | . + {total: (
        if .strict
        then ((.missing | length) + (.other_demos | length))
        else (.missing | length)
        end
      )}'
else
  if [[ -n "${MISSING_LIST}" ]]; then
    warn "resources MISSING ${TAG_KEY}:"
    echo "${MISSING_LIST}" | sed 's/^/  /'
  fi
  if [[ -n "${WRONG_LIST}" ]]; then
    if [[ "${STRICT}" -eq 1 ]]; then
      warn "resources with ${TAG_KEY} != ${TAG_VALUE} (--strict):"
    else
      log "resources with ${TAG_KEY} set to a different value (other demo, informational):"
    fi
    echo "${WRONG_LIST}" | awk -F'\t' '{printf "  %s   (currently: %s)\n", $1, $2}'
  fi
fi

if [[ "${FIX}" -eq 1 ]]; then
  if [[ -z "${MISSING_LIST}" ]]; then
    log "nothing to fix - resources flagged are all wrong-value, refusing to clobber another demo's tag"
    exit "${STRICT}"
  fi
  log "applying fix: ${TAG_KEY}=${TAG_VALUE} to MISSING resources only"
  # Pass only the missing list to fix_arns - we never overwrite an
  # existing splunk-demo value, so wrong-value resources are left alone.
  echo "${MISSING_LIST}" | sed 's/$/\t/' | fix_arns
  log "re-running audit to confirm..."
  REMAINING_RAW="$( { list_missing_or_wrong; list_missing_iam_roles; } )"
  REMAINING_MISSING="$(echo "${REMAINING_RAW}" | awk -F'\t' '$2 == "" {print $1}')"
  if [[ -z "${REMAINING_MISSING}" ]]; then
    log "OK - all NatWest demo resources now carry ${TAG_KEY}=${TAG_VALUE}"
    exit 0
  else
    warn "still untagged after fix attempt:"
    echo "${REMAINING_MISSING}" | sed 's/^/  /'
    exit 1
  fi
fi

exit 1
