# AWS EC2 CLI Guide: Basic Commands and Web01 Web Server Scripts

Works in **AWS CloudShell** or any terminal where `aws configure` has been completed.

---

## 1. Basic checks: who, where, which region

```bash
aws --version                         # CLI installed?
aws sts get-caller-identity           # which account/user you are
aws configure get region              # default region
aws configure list                    # full config summary
aws ec2 describe-regions --query 'Regions[].RegionName' --output text   # all regions
export AWS_DEFAULT_REGION=us-east-1   # switch region for this session
```

### Check where an instance was created (region and availability zone)

```bash
aws ec2 describe-instances \
  --query 'Reservations[].Instances[].[InstanceId,Placement.AvailabilityZone,State.Name,PublicIpAddress]' \
  --output table
```

Instances only show in the region you are querying. To scan every region:

```bash
for r in $(aws ec2 describe-regions --query 'Regions[].RegionName' --output text); do
  echo "== $r"
  aws ec2 describe-instances --region $r \
    --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text
done
```

---

## 2. Create an instance (manual steps)

```bash
# Latest Amazon Linux 2023 AMI
AMI=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)

# Key pair
aws ec2 create-key-pair --key-name MyKey --query KeyMaterial --output text > MyKey.pem
chmod 400 MyKey.pem

# Security group (allow HTTP)
aws ec2 create-security-group --group-name MySG --description "My SG"
aws ec2 authorize-security-group-ingress --group-name MySG --protocol tcp --port 80 --cidr 0.0.0.0/0

# Launch
aws ec2 run-instances --image-id $AMI --instance-type t3.micro \
  --key-name MyKey --security-groups MySG \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=Test01}]'
```

---

## 3. Verify resources

```bash
aws ec2 describe-instances --query 'Reservations[].Instances[].[InstanceId,State.Name,PublicIpAddress]' --output table
aws ec2 describe-instance-status --instance-ids i-xxxx
aws ec2 describe-security-groups --query 'SecurityGroups[].[GroupId,GroupName]' --output table
aws ec2 describe-key-pairs --query 'KeyPairs[].KeyName' --output text
aws ec2 describe-volumes --query 'Volumes[].[VolumeId,State]' --output table
aws ec2 describe-addresses            # Elastic IPs (cost money if unattached)
```

---

## 4. Stop, start and delete resources

```bash
aws ec2 stop-instances      --instance-ids i-xxxx
aws ec2 start-instances     --instance-ids i-xxxx
aws ec2 terminate-instances --instance-ids i-xxxx      # deletes the instance
aws ec2 wait instance-terminated --instance-ids i-xxxx
aws ec2 delete-security-group --group-name MySG        # only after the instance is terminated
aws ec2 delete-key-pair --key-name MyKey
```

---

## 5. Script 1: `Web01-Instance.sh` (create web server, deploy site from GitHub)

What it does:

1. Finds the latest Amazon Linux 2023 AMI and the default VPC
2. Creates a security group (ports 80 and 22), a key pair
3. Launches a `t3.micro` with user-data that installs Apache and Git and clones your GitHub website into `/var/www/html`
4. Saves all created IDs to `Web01-resources.env` and prints the public URL

```bash
#!/bin/bash
# Web01-Instance.sh
# Creates an EC2 web server (Apache) that pulls its website from GitHub.
# Usage: ./Web01-Instance.sh https://github.com/YOUR-USER/YOUR-REPO.git
set -euo pipefail

GITHUB_REPO="${1:-https://github.com/YOUR-USER/YOUR-WEBSITE-REPO.git}"
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
```

### How to run

```bash
chmod +x Web01-Instance.sh Web01-Cleanup.sh
./Web01-Instance.sh https://github.com/YOUR-USER/YOUR-WEBSITE-REPO.git
```

Wait 1 to 2 minutes, then open `http://<public-ip>` in a browser. If the GitHub clone fails, the server shows a fallback "Web01 is running" page, which proves Apache works.

---

## 6. Script 2: `Web01-Cleanup.sh` (delete everything created by Web01-Instance.sh)

What it does:

1. Reads `Web01-resources.env` and asks for confirmation
2. Terminates the instance and waits until it is gone
3. Deletes the security group (with retries) and the key pair
4. Removes local files and verifies nothing is left

```bash
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
```

### How to run

```bash
./Web01-Cleanup.sh
```

---

## 7. Notes and good practice

- The GitHub repository must be **public**, otherwise the clone fails without credentials.
- Port 22 (SSH) is open to the world for lab convenience; in real use, restrict it to your own IP (`--cidr YOUR.IP/32`).
- Always run the cleanup script when finished: running instances and unattached Elastic IPs keep billing.
- Keep `Web01-resources.env` until cleanup is done; it is how the cleanup script knows what to delete.
- If the website does not load, check that the security group allows port 80, then SSH in and run `sudo systemctl status httpd` and `sudo cat /var/log/cloud-init-output.log`.
