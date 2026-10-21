#!/bin/bash
# Project0
# Web01-Instance.sh
# Creates an EC2 web server (Apache) that pulls its website from GitHub.
# Usage: ./Web01-Instance.sh https://github.com/iqbalsound/website01.git
set -euo pipefail

GITHUB_REPO="${1:-https://github.com/iqbalsound/website01.git}"
NAME="Web01"
INSTANCE_TYPE="t3.micro"
KEY_NAME="${NAME}-Key"
SG_NAME="${NAME}-SG"
STATE_FILE="./${NAME}-resources.env"

# Region: use AWS_REGION / configured region, else us-east-1
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}"
REGION="${REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"

if [ -f "$STATE_FILE" ]; then
  echo "$STATE_FILE already exists. Run Web01-Cleanup.sh first."
  exit 1
fi

echo "Region: $REGION"
echo "Account: $(aws sts get-caller-identity --query Account --output text)"

# 1. Latest Amazon Linux 2023 AMI and default VPC
AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameter.Value' --output text)
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)
echo "AMI: $AMI_ID | VPC: $VPC_ID"

# 2. Security group (HTTP open to all; SSH open for lab use - restrict in real life)
SG_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" \
  --description "Web01 web server" --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null

# 3. Key pair
aws ec2 create-key-pair --key-name "$KEY_NAME" \
  --query 'KeyMaterial' --output text > "${KEY_NAME}.pem"
chmod 400 "${KEY_NAME}.pem"

# 4. User-data: install Apache + Git, deploy website from GitHub
cat > Web01-userdata.sh <<EOF
#!/bin/bash
dnf install -y httpd git
systemctl enable --now httpd
if git clone --depth 1 $GITHUB_REPO /tmp/site; then
  rm -rf /tmp/site/.git
  cp -r /tmp/site/* /var/www/html/
else
  echo "<h1>Web01 is running (GitHub clone failed)</h1>" > /var/www/html/index.html
fi
EOF

# 5. Launch instance
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" --security-group-ids "$SG_ID" \
  --user-data file://Web01-userdata.sh \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{Key=Project,Value=$NAME}]" \
  --query 'Instances[0].InstanceId' --output text)

# Save IDs so the cleanup script knows what to delete
cat > "$STATE_FILE" <<EOF
REGION=$REGION
INSTANCE_ID=$INSTANCE_ID
SG_ID=$SG_ID
KEY_NAME=$KEY_NAME
EOF

echo "Waiting for instance $INSTANCE_ID to run..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

echo "------------------------------------------"
echo "Instance ID : $INSTANCE_ID"
echo "Public IP   : $PUBLIC_IP"
echo "Website     : http://$PUBLIC_IP   (allow 1-2 minutes for setup)"
echo "SSH         : ssh -i ${KEY_NAME}.pem ec2-user@$PUBLIC_IP"
echo "------------------------------------------"
