#!/usr/bin/env bash
# STAGE 1 (Marc's account 236881431638, eu-west-2): AMI the Splunk box, re-encrypt
# its snapshot onto a SHAREABLE customer KMS key, share to Craig (445740536021).
# Non-disruptive: --no-reboot. Nothing here touches the running demo.
set -euo pipefail
P=natwest; R=eu-west-2; IID=i-03d32d2fd4cb5c02c
CRAIG=445740536021
TS=$(date +%Y%m%d-%H%M)
OUT="$(dirname "$0")/handoff.env"

echo "[1/6] create AMI (no-reboot)…"
AMI=$(aws --profile $P ec2 create-image --region $R --instance-id $IID --no-reboot \
  --name "natwest-splunk-clone-$TS" --description "Clone of NatWest Splunk box for London rebuild $TS" \
  --query ImageId --output text)
echo "  AMI=$AMI ; waiting until available (snapshot completes)…"
aws --profile $P ec2 wait image-available --region $R --image-ids $AMI

SNAP=$(aws --profile $P ec2 describe-images --region $R --image-ids $AMI \
  --query 'Images[0].BlockDeviceMappings[?Ebs].Ebs.SnapshotId' --output text)
echo "[2/6] AMI root snapshot=$SNAP"

echo "[3/6] create SHAREABLE customer KMS key (policy allows Craig $CRAIG)…"
POLICY=$(cat <<JSON
{"Version":"2012-10-17","Statement":[
 {"Sid":"Admin","Effect":"Allow","Principal":{"AWS":"arn:aws:iam::236881431638:root"},"Action":"kms:*","Resource":"*"},
 {"Sid":"CraigCrossAccount","Effect":"Allow","Principal":{"AWS":"arn:aws:iam::$CRAIG:root"},
  "Action":["kms:Decrypt","kms:DescribeKey","kms:CreateGrant","kms:ReEncrypt*","kms:GenerateDataKey*"],"Resource":"*"}
]}
JSON
)
CMK=$(aws --profile $P kms create-key --region $R --description "natwest-splunk-clone share key $TS" \
  --policy "$POLICY" --query KeyMetadata.KeyId --output text)
echo "  CMK=$CMK"

echo "[4/6] copy snapshot re-encrypting onto the shareable CMK…"
NEWSNAP=$(aws --profile $P ec2 copy-snapshot --region $R --source-region $R --source-snapshot-id $SNAP \
  --description "natwest-splunk-clone reencrypted $TS" --encrypted --kms-key-id $CMK \
  --query SnapshotId --output text)
echo "  NEWSNAP=$NEWSNAP ; waiting until completed…"
aws --profile $P ec2 wait snapshot-completed --region $R --snapshot-ids $NEWSNAP

echo "[5/6] share re-encrypted snapshot with Craig $CRAIG…"
aws --profile $P ec2 modify-snapshot-attribute --region $R --snapshot-id $NEWSNAP \
  --attribute createVolumePermission --operation-type add --user-ids $CRAIG

echo "[6/6] write handoff for stage 2:"
cat > "$OUT" <<EOF
SOURCE_AMI=$AMI
ORIG_SNAP=$SNAP
SHARED_SNAP=$NEWSNAP
SHARE_CMK=$CMK
SOURCE_REGION=$R
ARCH=x86_64
ROOT_DEV=/dev/xvda
EOF
cat "$OUT"
echo "DONE stage 1. Run 2-craig-side.sh next."
