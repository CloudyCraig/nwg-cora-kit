#!/usr/bin/env bash
# RESUME stage 2: poll the London snapshot copy (no aws-wait 10min cap), then register AMI.
set -euo pipefail
P=worldpay; DEST_R=eu-west-1
source "$(dirname "$0")/handoff.env"
DESTSNAP=snap-0ea8db493ecefb9d3   # created by 2-craig-side.sh copy step
TS=$(date +%Y%m%d-%H%M)

while :; do
  st=$(aws --profile $P ec2 describe-snapshots --region $DEST_R --snapshot-ids $DESTSNAP --query 'Snapshots[0].State' --output text 2>/dev/null || echo err)
  pr=$(aws --profile $P ec2 describe-snapshots --region $DEST_R --snapshot-ids $DESTSNAP --query 'Snapshots[0].Progress' --output text 2>/dev/null || echo "?")
  echo "  $DESTSNAP: $st $pr ($(date +%H:%M))"
  [ "$st" = "completed" ] && break
  [ "$st" = "error" ] && { echo "COPY ERROR"; exit 1; }
  sleep 60
done

echo "[register] London AMI from $DESTSNAP…"
NEWAMI=$(aws --profile $P ec2 register-image --region $DEST_R \
  --name "natwest-splunk-london-$TS" --description "NatWest Splunk box, London clone" \
  --architecture $ARCH --root-device-name $ROOT_DEV --ena-support --virtualization-type hvm \
  --block-device-mappings "[{\"DeviceName\":\"$ROOT_DEV\",\"Ebs\":{\"SnapshotId\":\"$DESTSNAP\",\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
  --query ImageId --output text)
echo "SHARED_SNAP=$SHARED_SNAP" >> "$(dirname "$0")/handoff.env"
echo "LONDON_AMI=$NEWAMI" >> "$(dirname "$0")/handoff.env"
echo "=== STAGE 2 COMPLETE — London AMI: $NEWAMI ==="
