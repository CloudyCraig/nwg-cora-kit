#!/usr/bin/env bash
# RESUME stage 1 against the already-created AMI (poll loops, no aws-wait 10min cap).
set -euo pipefail
P=natwest; R=eu-west-2; CRAIG=445740536021
AMI=ami-04a8a8b58482d329c
SNAP=snap-088072d29aab08fdc
OUT="$(dirname "$0")/handoff.env"; TS=$(date +%Y%m%d-%H%M)

poll_snap(){ # $1 snapshot id — block until completed
  while :; do
    st=$(aws --profile $P ec2 describe-snapshots --region $R --snapshot-ids "$1" --query 'Snapshots[0].State' --output text 2>/dev/null || echo err)
    pr=$(aws --profile $P ec2 describe-snapshots --region $R --snapshot-ids "$1" --query 'Snapshots[0].Progress' --output text 2>/dev/null || echo "?")
    echo "  $1: $st $pr ($(date +%H:%M))"
    [ "$st" = "completed" ] && break
    [ "$st" = "error" ] && { echo "SNAPSHOT ERROR"; exit 1; }
    sleep 60
  done
}

echo "[wait] source snapshot $SNAP to complete…"; poll_snap "$SNAP"

echo "[3/6] create SHAREABLE customer CMK (allows Craig $CRAIG)…"
POLICY='{"Version":"2012-10-17","Statement":[{"Sid":"Admin","Effect":"Allow","Principal":{"AWS":"arn:aws:iam::236881431638:root"},"Action":"kms:*","Resource":"*"},{"Sid":"CraigCrossAccount","Effect":"Allow","Principal":{"AWS":"arn:aws:iam::445740536021:root"},"Action":["kms:Decrypt","kms:DescribeKey","kms:CreateGrant","kms:ReEncrypt*","kms:GenerateDataKey*"],"Resource":"*"}]}'
CMK=$(aws --profile $P kms create-key --region $R --description "natwest-splunk-clone share key $TS" --policy "$POLICY" --query KeyMetadata.KeyId --output text)
echo "  CMK=$CMK"

echo "[4/6] copy snapshot re-encrypting onto CMK…"
NEWSNAP=$(aws --profile $P ec2 copy-snapshot --region $R --source-region $R --source-snapshot-id $SNAP \
  --description "natwest-splunk-clone reencrypted $TS" --encrypted --kms-key-id $CMK --query SnapshotId --output text)
echo "  NEWSNAP=$NEWSNAP"; poll_snap "$NEWSNAP"

echo "[5/6] share re-encrypted snapshot with Craig $CRAIG…"
aws --profile $P ec2 modify-snapshot-attribute --region $R --snapshot-id $NEWSNAP \
  --attribute createVolumePermission --operation-type add --user-ids $CRAIG

cat > "$OUT" <<EOF
SOURCE_AMI=$AMI
ORIG_SNAP=$SNAP
SHARED_SNAP=$NEWSNAP
SHARE_CMK=$CMK
SOURCE_REGION=$R
ARCH=x86_64
ROOT_DEV=/dev/xvda
EOF
echo "=== STAGE 1 COMPLETE ==="; cat "$OUT"
