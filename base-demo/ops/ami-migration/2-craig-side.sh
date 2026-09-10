#!/usr/bin/env bash
# STAGE 2 (Craig's account 445740536021, eu-west-1): pull the shared re-encrypted
# snapshot, re-encrypt onto Craig's OWN key, register a launchable AMI.
# Reads handoff.env from stage 1.
set -euo pipefail
P=worldpay                     # Craig's account 445740536021
DEST_R=eu-west-1               # London
source "$(dirname "$0")/handoff.env"
TS=$(date +%Y%m%d-%H%M)

echo "[1/3] copy shared snapshot $SHARED_SNAP ($SOURCE_REGION) -> $DEST_R, re-encrypt with Craig's default EBS key…"
DESTSNAP=$(aws --profile $P ec2 copy-snapshot --region $DEST_R --source-region $SOURCE_REGION \
  --source-snapshot-id $SHARED_SNAP --description "natwest-splunk London clone $TS" --encrypted \
  --query SnapshotId --output text)
echo "  DESTSNAP=$DESTSNAP ; waiting…"
aws --profile $P ec2 wait snapshot-completed --region $DEST_R --snapshot-ids $DESTSNAP

echo "[2/3] register launchable AMI from the London snapshot…"
NEWAMI=$(aws --profile $P ec2 register-image --region $DEST_R \
  --name "natwest-splunk-london-$TS" --description "NatWest Splunk box, London clone" \
  --architecture $ARCH --root-device-name $ROOT_DEV --ena-support --virtualization-type hvm \
  --block-device-mappings "[{\"DeviceName\":\"$ROOT_DEV\",\"Ebs\":{\"SnapshotId\":\"$DESTSNAP\",\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
  --query ImageId --output text)
echo "  NEWAMI=$NEWAMI"

echo "[3/3] AMI ready to launch in $DEST_R. Launch e.g.:"
echo "  aws --profile $P ec2 run-instances --region $DEST_R --image-id $NEWAMI \\"
echo "     --instance-type c5a.4xlarge --key-name <your-key> --security-group-ids <sg> --subnet-id <subnet>"
echo "  (c5a.4xlarge is ample; source was 8xlarge. Then repoint hostname/DNS + o11y tokens.)"
echo "DONE. London AMI: $NEWAMI"
