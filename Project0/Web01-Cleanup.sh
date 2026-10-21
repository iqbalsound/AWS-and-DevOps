#!/bin/bash
# Web01-Cleanup.sh
# Deletes every resource created by Web01-Instance.sh
set -uo pipefail

STATE_FILE="./Web01-resources.env"
if [ ! -f "$STATE_FILE" ]; then
  echo "$STATE_FILE not found - nothing to delete."
  exit 1
fi
source "$STATE_FILE"
export AWS_DEFAULT_REGION="$REGION"

echo "This will delete in $REGION:"
echo "  Instance : $INSTANCE_ID"
echo "  Sec group: $SG_ID"
echo "  Key pair : $KEY_NAME"
read -r -p "Continue? (y/N) " ans
[ "$ans" = "y" ] || { echo "Cancelled."; exit 0; }

# 1. Terminate instance
echo "Terminating instance..."
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
echo "Instance terminated."

# 2. Delete security group (retry, it can take a few seconds to release)
for i in 1 2 3 4 5 6; do
  if aws ec2 delete-security-group --group-id "$SG_ID" 2>/dev/null; then
    echo "Security group deleted."
    break
  fi
  echo "Security group still in use, retrying ($i/6)..."
  sleep 10
done

# 3. Delete key pair and local files
aws ec2 delete-key-pair --key-name "$KEY_NAME"
rm -f "${KEY_NAME}.pem" Web01-userdata.sh "$STATE_FILE"
echo "Key pair and local files deleted."

# 4. Verify
echo "Remaining Web01 instances (should be terminated/none):"
aws ec2 describe-instances --filters "Name=tag:Project,Values=Web01" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text
echo "Cleanup complete."
