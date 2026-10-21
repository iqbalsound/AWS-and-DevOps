#!/usr/bin/env bash
# =============================================================================
# cleanup-demo-aws.sh  -  removes EVERYTHING the AWS demo created
# Run in AWS CloudShell:  export STUDENT_ID=iqbal01 ; ./cleanup-demo-aws.sh
# Skip the question with:  CONFIRM=yes ./cleanup-demo-aws.sh      (set REGION if you did not use ap-south-1)
# =============================================================================
set -uo pipefail
say() { echo "==> $*"; }; ok() { echo "[ OK ] $*"; }; warn() { echo "[WARN] $*"; }; die() { echo "[FAIL] $*" >&2; exit 1; }
STUDENT_ID="${STUDENT_ID:-}"; REGION="${REGION:-ap-south-1}"
export AWS_DEFAULT_REGION="$REGION" AWS_PAGER=""
[[ "$STUDENT_ID" =~ ^[a-z0-9]{3,8}$ ]] || die "Set STUDENT_ID first, e.g.: export STUDENT_ID=iqbal01"
aws sts get-caller-identity >/dev/null 2>&1 || die "Not signed in to AWS."
P="demo-$STUDENT_ID"; ROLE="$P-role"; PROFILE="$P-profile"; WORK="$HOME/demo-aws-$STUDENT_ID"
F=("Name=tag:owner,Values=$STUDENT_ID" "Name=tag:project,Values=capstone-demo")

IDS=$(aws ec2 describe-instances --filters "${F[@]}" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text)
VPCS=$(aws ec2 describe-vpcs --filters "${F[@]}" --query 'Vpcs[].VpcId' --output text)
say "Region $REGION. Found instances: ${IDS:-none}   VPCs: ${VPCS:-none}"
if [ "${CONFIRM:-}" != yes ]; then read -r -p "Type the student id ($STUDENT_ID) to confirm deletion: " ans; [ "$ans" = "$STUDENT_ID" ] || die "Not confirmed. Nothing was deleted."; fi

if [ -n "$IDS" ]; then
  say "Terminating instances (their EBS disks are deleted with them) ..."
  aws ec2 terminate-instances --instance-ids $IDS >/dev/null; aws ec2 wait instance-terminated --instance-ids $IDS && ok "instances terminated"
fi
say "Alarm and SNS topic"
aws cloudwatch delete-alarms --alarm-names "$P-cpu" 2>/dev/null && ok "alarm deleted"
for t in $(aws sns list-topics --query "Topics[?ends_with(TopicArn,':$P-alerts')].TopicArn" --output text); do aws sns delete-topic --topic-arn "$t" && ok "topic deleted"; done
say "IAM instance profile and role"
aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE" --role-name "$ROLE" 2>/dev/null
aws iam delete-instance-profile --instance-profile-name "$PROFILE" 2>/dev/null && ok "instance profile deleted"
aws iam detach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null
aws iam delete-role --role-name "$ROLE" 2>/dev/null && ok "role deleted"

for vpc in $VPCS; do
  say "Deleting network $vpc"
  for sg in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
    for n in 1 2 3 4 5 6; do aws ec2 delete-security-group --group-id "$sg" 2>/dev/null && { ok "security group $sg deleted"; break; }; sleep 10; done
  done
  for rt in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc" --query "RouteTables[?length(Associations[?Main==\`true\`])==\`0\`].RouteTableId" --output text); do
    for a in $(aws ec2 describe-route-tables --route-table-ids "$rt" --query 'RouteTables[0].Associations[].RouteTableAssociationId' --output text); do aws ec2 disassociate-route-table --association-id "$a"; done
    aws ec2 delete-route-table --route-table-id "$rt" && ok "route table $rt deleted"
  done
  for sub in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[].SubnetId' --output text); do aws ec2 delete-subnet --subnet-id "$sub" && ok "subnet $sub deleted"; done
  for igw in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc" --query 'InternetGateways[].InternetGatewayId' --output text); do
    aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc"; aws ec2 delete-internet-gateway --internet-gateway-id "$igw" && ok "internet gateway $igw deleted"
  done
  aws ec2 delete-vpc --vpc-id "$vpc" && ok "VPC $vpc deleted"
done

say "Final check"
left_i=$(aws ec2 describe-instances --filters "${F[@]}" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'length(Reservations[].Instances[])' --output text)
left_v=$(aws ec2 describe-vpcs --filters "${F[@]}" --query 'length(Vpcs)' --output text)
left_vol=$(aws ec2 describe-volumes --filters "${F[@]}" --query 'length(Volumes)' --output text)
left_r=$(aws iam get-role --role-name "$ROLE" >/dev/null 2>&1 && echo 1 || echo 0)
if [ "$left_i$left_v$left_vol$left_r" = "0000" ]; then ok "CLEAN: no instances, volumes, VPC or IAM role left for $STUDENT_ID"; else warn "Left over: instances=$left_i vpcs=$left_v volumes=$left_vol role=$left_r. Re-run this script, then check the console."; fi
[ -f "$WORK/timeline.log" ] && cp "$WORK/timeline.log" "$HOME/demo-timeline-$STUDENT_ID.log"
rm -rf "$WORK"; ok "Local work folder removed (timeline copy kept in your home folder)"
echo "Still to check by hand: Billing > Free Tier (usage), and the SNS confirmation e-mail can be ignored."
