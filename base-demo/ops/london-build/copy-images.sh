#!/usr/bin/env bash
# Copy the exact deployed image tags from Marc's ECR (eu-west-2 / 236881431638)
# to Craig's ECR (eu-west-1 / 445740536021). Tags ECR repos with splunk-demo/NWG-demo.
set -uo pipefail
SRC=236881431638.dkr.ecr.eu-west-2.amazonaws.com
DST=445740536021.dkr.ecr.eu-west-1.amazonaws.com
# auth crane to both registries
aws --profile natwest  ecr get-login-password --region eu-west-2 | crane auth login "$SRC" -u AWS --password-stdin
aws --profile worldpay ecr get-login-password --region eu-west-1 | crane auth login "$DST" -u AWS --password-stdin

# repo:tag pairs actually deployed
IMAGES=(
  "natwest-payments-service:0.1.6"
  "natwest-payments-service:0.1.9-madrid-rca"
  "natwest-payments-chaos-controller:0.1.12-aml-err90"
  "natwest-payments-ledger-service-java:0.1.7"
  "natwest-payments-rum-user-simulator:0.1.4"
  "natwest-payments-traffic-generator:0.1.6-madrid-bronze"
  "natwest-payments-web-frontend:0.7.9-partialfail"
)
for img in "${IMAGES[@]}"; do
  repo="${img%%:*}"
  aws --profile worldpay ecr describe-repositories --region eu-west-1 --repository-names "$repo" >/dev/null 2>&1 \
    || aws --profile worldpay ecr create-repository --region eu-west-1 --repository-name "$repo" \
         --tags Key=splunk-demo,Value=NWG-demo >/dev/null 2>&1
  echo "copy $img …"
  crane copy "$SRC/$img" "$DST/$img" && echo "  ok $img" || echo "  FAIL $img"
done
echo "=== image copy done. Repos in $DST:"
aws --profile worldpay ecr describe-repositories --region eu-west-1 --query 'repositories[?starts_with(repositoryName,`natwest`)].repositoryName' --output text
