#!/usr/bin/env bash
# =============================================================================
# demo-aws.sh - Final Demo task (beginner), AWS edition. Run in AWS CloudShell.
# Cleanup: cleanup-demo-aws.sh
# =============================================================================
# ============================== common helpers ==============================
set -uo pipefail
c_g=$'\033[1;32m'; c_y=$'\033[1;33m'; c_r=$'\033[1;31m'; c_p=$'\033[1;35m'; c_0=$'\033[0m'
say()  { echo "${c_p}==>${c_0} $*"; }
ok()   { echo "${c_g}[ OK ]${c_0} $*"; }
warn() { echo "${c_y}[WARN]${c_0} $*"; }
die()  { echo "${c_r}[FAIL]${c_0} $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing tool: $1"; }

STUDENT_ID="${STUDENT_ID:-}"   # 3-8 lowercase letters or digits, e.g. iqbal02
MY_IP="${MY_IP:-}"             # your PUBLIC IP from your own browser (https://ifconfig.me)
EMAIL="${EMAIL:-}"             # where the alert e-mail goes

save() { { grep -v "^$1=" "$STATE" 2>/dev/null || true; echo "$1=\"$2\""; } > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"; }

init_workspace() {
  [[ "$STUDENT_ID" =~ ^[a-z0-9]{3,8}$ ]] || die "Set STUDENT_ID first (3-8 lowercase letters/digits), e.g.: export STUDENT_ID=iqbal02"
  P="demo-$STUDENT_ID"; WORK="$HOME/demo-$CLOUD-$STUDENT_ID"; mkdir -p "$WORK"
  STATE="$WORK/state.env"; TIMELINE="$WORK/timeline.log"; touch "$STATE" "$TIMELINE"
  # shellcheck disable=SC1090
  . "$STATE"
  if [ -z "${TOKEN:-}" ]; then TOKEN=$(printf '%s' "$STUDENT_ID-$(date +%s)" | sha256sum | cut -c1-6); save TOKEN "$TOKEN"; fi
}

need_my_ip() {
  [[ "$MY_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Set MY_IP to your public IP (open https://ifconfig.me in YOUR laptop browser), e.g.: export MY_IP=203.0.113.7"
  [ "$MY_IP" != "0.0.0.0" ] || die "MY_IP must be your own address, never 0.0.0.0"
}

phase_run() { # phase_run NAME FUNCTION  (times every phase for the report)
  local n=$1 f=$2 s e rc; s=$(date +%s); say "STEP $n starting"
  "$f"; rc=$?; e=$(date +%s); echo "$n $s $e $rc" >> "$TIMELINE"
  [ $rc -eq 0 ] && ok "STEP $n finished in $((e-s))s" || warn "STEP $n ended with code $rc"
  return $rc
}

phase_report() {
  say "Time report for $STUDENT_ID"
  awk '{ n[NR]=$1; s[NR]=$2; e[NR]=$3; pt+=($3-$2); if(NR==1||$2<first) first=$2; if($3>last) last=$3 }
    END { if (NR==0) { print "nothing recorded yet"; exit }
      printf "%-10s %8s\n","step","minutes"; for(i=1;i<=NR;i++) printf "%-10s %8.1f\n",n[i],(e[i]-s[i])/60;
      lt=last-first; printf "\nScript working time : %6.1f min\nWhole session       : %6.1f min\n",pt/60,lt/60 }' "$TIMELINE"
  echo "Token: $TOKEN   Student: $STUDENT_ID   Time: $(date '+%F %T %Z')"
}

# The server installs Docker, builds TWO versions of a tiny website (v1, v2) and runs v1 on port 80.
make_userdata() {
  cat > "$WORK/ud.sh" <<'UD'
#!/bin/bash
exec >> /var/log/demo-bootstrap.log 2>&1
set -x
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y docker.io curl
systemctl enable --now docker
mkdir -p /opt/demo && cd /opt/demo
cat > Dockerfile <<'DF'
FROM nginx:stable-alpine
COPY index.html /usr/share/nginx/html/index.html
DF
for v in 1 2; do
  printf '<html><body style="font-family:sans-serif;background:#1a0b2e;color:#39ff14;padding:2em"><h1>DevOps Demo v%s</h1><p>Owner: OWNER_ID</p><p>Token: TOKEN_VALUE</p></body></html>\n' "$v" > index.html
  docker build -t "demo-web:v$v" .
done
docker run -d --name web --restart=always -p 80:80 demo-web:v1
touch /var/lib/demo-ready
UD
  sed -i "s/OWNER_ID/$STUDENT_ID/; s/TOKEN_VALUE/$TOKEN/" "$WORK/ud.sh"
}

# =============================== AWS specifics ==============================
CLOUD=aws
REGION="${REGION:-ap-south-1}"
export AWS_DEFAULT_REGION="$REGION" AWS_PAGER=""
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"   # must be free-tier eligible in YOUR account

usage() {
cat <<USAGE
Demo (AWS)  -  usage:  ./demo-aws.sh <step>

  First:  export STUDENT_ID=iqbal02  MY_IP=<your public IP>  EMAIL=<you@mail>

  check      safe test: login, region, instance type (creates nothing)
  build      creates the network, firewall, server and website (about 6 minutes)
  wait       waits until the server is ready
  status     prints the website address
  update     switch the website to version 2
  breakit    try to start a version that does not exist; the site must stay up
  rollback   go back to version 1
  monitor    create a CPU alarm (needs EMAIL; confirm the e-mail from AWS)
  load       6 minutes of CPU load to test the alarm
  verify     automatic check and score (take a screenshot)
  run "<cmd>"  run a Linux command on the server
  report     time report
USAGE
}

tspec() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=project,Value=capstone-demo},{Key=owner,Value=$STUDENT_ID}]"; }
set_names() { ROLE_NAME="$P-role"; PROFILE="$P-profile"; }
find_instance() { aws ec2 describe-instances --filters "Name=tag:owner,Values=$STUDENT_ID" "Name=tag:project,Values=capstone-demo" \
  "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId | [0]' --output text 2>/dev/null; }

remote() { # run a command through Systems Manager (no SSH needed)
  local id cid st i; id=$(find_instance); [ -n "$id" ] && [ "$id" != None ] || die "No server found. Run build first."
  cid=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript --parameters "$(jq -n --arg c "$1" '{commands:[$c]}')" \
        --query Command.CommandId --output text) || return 1
  for i in $(seq 1 100); do
    st=$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query Status --output text 2>/dev/null)
    case "$st" in Success|Failed|Cancelled|TimedOut) break;; esac; sleep 3
  done
  aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query '[StandardOutputContent,StandardErrorContent]' --output text
}

phase_check() {
  need aws; need jq; need curl; need_my_ip
  aws sts get-caller-identity >/dev/null 2>&1 || die "Not signed in. Open AWS CloudShell from the console toolbar."
  local elig; elig=$(aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true --query 'InstanceTypes[].InstanceType' --output text 2>/dev/null)
  if ! echo " $elig " | grep -q "$INSTANCE_TYPE"; then
    [ "${CONFIRM_PAID:-no}" = yes ] || die "$INSTANCE_TYPE is not free-tier eligible here. Eligible: $elig . Use: export INSTANCE_TYPE=<one of them>"
  fi
  ok "Region $REGION, type $INSTANCE_TYPE is free-tier eligible. Your IP: $MY_IP"
}

phase_build() {
  need_my_ip; make_userdata
  local trust="$WORK/trust.json" vpc igw sub rt sg ami
  cat > "$trust" <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "file://$trust" --tags Key=project,Value=capstone-demo >/dev/null
  aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam create-instance-profile --instance-profile-name "$PROFILE" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE" --role-name "$ROLE_NAME"
  ok "Role for the server (lets us run commands without SSH)"
  vpc=$(aws ec2 create-vpc --cidr-block 10.60.0.0/16 --tag-specifications "$(tspec vpc "$P-vpc")" --query Vpc.VpcId --output text) || die "VPC failed"
  igw=$(aws ec2 create-internet-gateway --tag-specifications "$(tspec internet-gateway "$P-igw")" --query InternetGateway.InternetGatewayId --output text)
  aws ec2 attach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc"
  sub=$(aws ec2 create-subnet --vpc-id "$vpc" --cidr-block 10.60.1.0/24 --tag-specifications "$(tspec subnet "$P-subnet")" --query Subnet.SubnetId --output text)
  aws ec2 modify-subnet-attribute --subnet-id "$sub" --map-public-ip-on-launch
  rt=$(aws ec2 create-route-table --vpc-id "$vpc" --tag-specifications "$(tspec route-table "$P-rt")" --query RouteTable.RouteTableId --output text)
  aws ec2 create-route --route-table-id "$rt" --destination-cidr-block 0.0.0.0/0 --gateway-id "$igw" >/dev/null
  aws ec2 associate-route-table --route-table-id "$rt" --subnet-id "$sub" >/dev/null
  sg=$(aws ec2 create-security-group --group-name "$P-sg" --description "demo web from student only" --vpc-id "$vpc" --tag-specifications "$(tspec security-group "$P-sg")" --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "$sg" --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=$MY_IP/32,Description=web-from-student}]" >/dev/null
  ok "Network ready. Firewall: only YOUR IP may open port 80"; save SG "$sg"
  ami=$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id --query Parameter.Value --output text) || die "AMI lookup failed"
  local extra=(); case "$INSTANCE_TYPE" in t2.*|t3.*) extra=(--credit-specification CpuCredits=standard);; esac
  local id="" try
  for try in 1 2 3 4 5 6; do
    id=$(aws ec2 run-instances --image-id "$ami" --instance-type "$INSTANCE_TYPE" --subnet-id "$sub" --security-group-ids "$sg" \
      --iam-instance-profile "Name=$PROFILE" --user-data "file://$WORK/ud.sh" --metadata-options HttpTokens=required,HttpEndpoint=enabled \
      --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3,DeleteOnTermination=true}' "${extra[@]}" \
      --tag-specifications "$(tspec instance "$P-vm")" "$(tspec volume "$P-disk")" --query 'Instances[0].InstanceId' --output text 2>/dev/null) && break
    say "role not ready yet, retrying ($try/6) ..."; sleep 10
  done
  [ -n "$id" ] || die "run-instances failed"; ok "Server $id created. Next: ./demo-aws.sh wait"
}

phase_wait() {
  local id n=0 out; id=$(find_instance)
  while [ $n -lt 40 ]; do
    [ "$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$id" --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)" = Online ] && break
    n=$((n+1)); say "waiting for the management agent ($n/40) ..."; sleep 15
  done
  n=0
  while [ $n -lt 40 ]; do
    out=$(remote 'test -f /var/lib/demo-ready && echo READY || echo WAIT' 2>/dev/null | grep -Eo 'READY|WAIT' | head -n1)
    [ "$out" = READY ] && { ok "Server is ready"; return 0; }
    n=$((n+1)); say "still installing ($n/40) ..."; sleep 15
  done
  die "Not ready. Read the log: ./demo-aws.sh run 'tail -n 30 /var/log/demo-bootstrap.log'"
}

phase_status() {
  local ip; ip=$(aws ec2 describe-instances --instance-ids "$(find_instance)" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  echo; echo "Open in YOUR laptop browser:  http://$ip"; echo "You should see: DevOps Demo v1 | Owner: $STUDENT_ID | Token: $TOKEN"
}

phase_update()   { remote 'docker rm -f web >/dev/null; docker run -d --name web --restart=always -p 80:80 demo-web:v2 >/dev/null && curl -s localhost | grep -o "DevOps Demo v[0-9]"'; }
phase_rollback() { remote 'docker rm -f web >/dev/null; docker run -d --name web --restart=always -p 80:80 demo-web:v1 >/dev/null && curl -s localhost | grep -o "DevOps Demo v[0-9]"'; }
phase_breakit()  { remote 'docker run -d --name web-bad demo-web:v9 2>&1 | tail -n 2; echo "--- the site is still answering:"; curl -s localhost | grep -o "DevOps Demo v[0-9]"'; }

phase_monitor() {
  [ -n "$EMAIL" ] || die "Set EMAIL first: export EMAIL=you@example.com"
  local topic; topic=$(aws sns create-topic --name "$P-alerts" --tags Key=project,Value=capstone-demo --query TopicArn --output text)
  aws sns subscribe --topic-arn "$topic" --protocol email --notification-endpoint "$EMAIL" >/dev/null
  ok "OPEN YOUR MAILBOX and click Confirm subscription."
  aws cloudwatch put-metric-alarm --alarm-name "$P-cpu" --namespace AWS/EC2 --metric-name CPUUtilization --dimensions "Name=InstanceId,Value=$(find_instance)" \
    --statistic Average --period 300 --evaluation-periods 1 --threshold 70 --comparison-operator GreaterThanThreshold --alarm-actions "$topic" \
    --tags Key=project,Value=capstone-demo && ok "Alarm: CPU above 70 percent"
}
phase_load() { remote "nohup timeout 360 sh -c 'while :; do :; done' >/dev/null 2>&1 &"; ok "Load started. Watch CloudWatch > Alarms (5 to 10 minutes)."; }

phase_verify() {
  local pass=0 total=0 out
  chk() { total=$((total+1)); if [ "$2" = "$3" ]; then pass=$((pass+1)); ok "$1"; else warn "FAIL: $1 (got '$2', expected '$3')"; fi; }
  out=$(aws ec2 describe-vpcs --filters "Name=tag:owner,Values=$STUDENT_ID" "Name=tag:project,Values=capstone-demo" --query 'length(Vpcs)' --output text 2>/dev/null); chk "Network exists and is tagged" "$out" "1"
  out=$(aws ec2 describe-security-groups --group-ids "${SG:-none}" --query "length(SecurityGroups[0].IpPermissions[?IpRanges[?CidrIp=='0.0.0.0/0']])" --output text 2>/dev/null)
  chk "No firewall rule is open to the whole internet (and no SSH)" "$out" "0"
  out=$(aws ec2 describe-instances --instance-ids "$(find_instance)" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null); chk "Server is running" "$out" "running"
  out=$(remote 'test -f /var/lib/demo-ready && echo READY' 2>/dev/null | grep -o READY | head -n1); chk "Server finished installing" "$out" "READY"
  out=$(remote 'curl -s localhost' | grep -o "Token: $TOKEN" | head -n1); chk "Website shows your token" "$out" "Token: $TOKEN"
  out=$(aws cloudwatch describe-alarms --alarm-names "$P-cpu" --query 'MetricAlarms[0].AlarmName' --output text 2>/dev/null); chk "CPU alarm exists" "$out" "$P-cpu"
  echo; echo "SCORE: $pass / $total      Token: $TOKEN      Student: $STUDENT_ID      $(date '+%F %T %Z')"
}

main() {
  local cmd="${1:-help}"; shift || true
  [ "$cmd" = help ] && { usage; exit 0; }
  need aws; init_workspace; set_names
  case "$cmd" in
    check|build|wait|status|update|breakit|rollback|monitor|load|verify) phase_run "$cmd" "phase_$cmd" ;;
    run) remote "${1:?command}" ;;
    report) phase_report ;;
    *) usage; exit 1 ;;
  esac
}
main "$@"
