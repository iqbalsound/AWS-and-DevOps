#!/usr/bin/env bash
# =============================================================================
# capstone-aws.sh  -  DevOps Bootcamp Capstone (AZ-400 + AZ-104 concepts), AWS edition
# Run in AWS CloudShell. Free-tier instance types. One script, many phases.
# Cleanup: cleanup-aws.sh   (always run it before you leave)
# =============================================================================
# ============================== common helpers ==============================
set -uo pipefail
c_g=$'\033[1;32m'; c_y=$'\033[1;33m'; c_r=$'\033[1;31m'; c_p=$'\033[1;35m'; c_0=$'\033[0m'
say()  { echo "${c_p}==>${c_0} $*"; }
ok()   { echo "${c_g}[ OK ]${c_0} $*"; }
warn() { echo "${c_y}[WARN]${c_0} $*"; }
die()  { echo "${c_r}[FAIL]${c_0} $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing tool: $1"; }

STUDENT_ID="${STUDENT_ID:-}"      # 3-8 lowercase letters/digits, e.g. iqbal01
MY_IP="${MY_IP:-}"                # your PUBLIC IP as seen by your browser (https://ifconfig.me)
EMAIL="${EMAIL:-}"                # where the CPU alert e-mail is sent
REG_IP="10.50.1.10"               # private IP of the CI server (Jenkins + registry)
K8S_IP="10.50.1.11"               # private IP of the Kubernetes (K3s) server

save() { # save KEY VALUE  -> persists to the state file
  { grep -v "^$1=" "$STATE" 2>/dev/null || true; echo "$1=\"$2\""; } > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

init_workspace() {
  [[ "$STUDENT_ID" =~ ^[a-z0-9]{3,8}$ ]] || die "Set STUDENT_ID first (3-8 lowercase letters/digits), e.g.: export STUDENT_ID=iqbal01"
  P="cap-$STUDENT_ID"
  WORK="$HOME/capstone-$CLOUD-$STUDENT_ID"; mkdir -p "$WORK"
  STATE="$WORK/state.env"; TIMELINE="$WORK/timeline.log"; touch "$STATE" "$TIMELINE"
  # shellcheck disable=SC1090
  . "$STATE"
  if [ -z "${TOKEN:-}" ]; then
    TOKEN=$(printf '%s' "$STUDENT_ID-$(date +%s)" | sha256sum | cut -c1-6); save TOKEN "$TOKEN"
  fi
}

# Every phase is timed: this feeds the value-stream report (Day 1 skill).
phase_run() { # phase_run NAME FUNCTION
  local n=$1 f=$2 s e rc; s=$(date +%s); say "PHASE $n starting"
  "$f"; rc=$?; e=$(date +%s); echo "$n $s $e $rc" >> "$TIMELINE"
  [ $rc -eq 0 ] && ok "PHASE $n finished in $((e-s))s" || warn "PHASE $n ended with code $rc"
  return $rc
}

phase_report() {
  say "Value-stream report for $STUDENT_ID (Day 1: lead time, process time, wait time)"
  awk '
    { n[NR]=$1; s[NR]=$2; e[NR]=$3; pt+=($3-$2); if(NR==1||$2<first) first=$2; if($3>last) last=$3 }
    END {
      if (NR==0) { print "no phases recorded yet"; exit }
      printf "%-12s %8s\n", "phase", "minutes";
      for (i=1;i<=NR;i++) printf "%-12s %8.1f\n", n[i], (e[i]-s[i])/60;
      lt=last-first; wt=lt-pt;
      printf "\nProcess time (script working) : %6.1f min\n", pt/60;
      printf "Wait time (you + the cloud)   : %6.1f min\n", wt/60;
      printf "Lead time (first to last)     : %6.1f min\n", lt/60;
      if (lt>0) printf "Flow efficiency               : %6.1f %%\n", 100*pt/lt;
    }' "$TIMELINE"
  echo "Your token: $TOKEN   Student: $STUDENT_ID   Time: $(date '+%F %T %Z')"
}

# --------------------------- the app bundle ---------------------------------
# Everything the servers need (app, tests, Dockerfile, Jenkinsfile, k8s YAML,
# Ansible playbook, bootstrap) is generated here and shipped inside user-data.
make_bundle() {
  local B="$WORK/bundle"; rm -rf "$B"; mkdir -p "$B/app" "$B/tests" "$B/k8s" "$B/ansible"
  : > "$B/app/__init__.py"
  cat > "$B/app/main.py" <<'PY'
import os
import socket
from flask import Flask

app = Flask(__name__)
VERSION = os.environ.get("APP_VERSION", "dev")
OWNER = os.environ.get("OWNER", "student")
TOKEN = os.environ.get("TOKEN", "none")


@app.route("/")
def home():
    return f"Capstone app v{VERSION} | owner={OWNER} | token={TOKEN}\n"


@app.route("/health")
def health():
    return "ok"


@app.route("/host")
def host():
    return socket.gethostname() + "\n"
PY
  cat > "$B/tests/test_app.py" <<'PY'
from app.main import app


def test_home():
    assert b"Capstone app" in app.test_client().get("/").data


def test_health():
    assert app.test_client().get("/health").data == b"ok"
PY
  printf 'flask==3.0.3\ngunicorn==22.0.0\npytest==8.3.2\n' > "$B/requirements.txt"
  printf 'flask==3.0.3\ngunicorn==22.0.0\n' > "$B/requirements-runtime.txt"
  printf '.git\n.venv\n__pycache__\n.pytest_cache\ntests\nk8s\nansible\nbootstrap.sh\nJenkinsfile\n' > "$B/.dockerignore"
  cat > "$B/Dockerfile" <<'DF'
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements-runtime.txt .
RUN pip install --no-cache-dir -r requirements-runtime.txt
COPY app ./app
ARG APP_VERSION=1.0
ENV APP_VERSION=$APP_VERSION
RUN useradd --create-home --uid 10001 appuser
USER appuser
EXPOSE 5000
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "app.main:app"]
DF
  cat > "$B/Jenkinsfile" <<'JF'
pipeline {
  agent any
  options { timestamps(); timeout(time: 15, unit: 'MINUTES') }
  environment { REGISTRY = 'localhost:5000'; IMAGE = 'capstone-app' }
  stages {
    stage('Checkout') { steps { checkout scm } }
    stage('Test') {
      steps {
        sh '''
          python3 -m venv .venv
          .venv/bin/pip install -q -r requirements.txt
          mkdir -p reports
          .venv/bin/python -m pytest -q --junitxml=reports/junit.xml
        '''
      }
      post { always { junit 'reports/junit.xml' } }
    }
    stage('Build image') {
      steps { sh 'docker build -t $REGISTRY/$IMAGE:$BUILD_NUMBER --build-arg APP_VERSION=$BUILD_NUMBER .' }
    }
    stage('Scan image') {
      // --exit-code 0 only reports. Change to 1 to FAIL the build on CRITICAL findings.
      steps { sh 'docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy:latest image --severity CRITICAL --exit-code 0 $REGISTRY/$IMAGE:$BUILD_NUMBER' }
    }
    stage('Approval') {
      steps { timeout(time: 10, unit: 'MINUTES') { input message: 'Publish this build to the registry?' } }
    }
    stage('Publish') { steps { sh 'docker push $REGISTRY/$IMAGE:$BUILD_NUMBER' } }
  }
  post { failure { echo 'capstone-app: build FAILED - open Console Output and Test Result' } }
}
JF
  cat > "$B/k8s/deployment.yaml" <<'KY'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: capstone-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: capstone-app
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: capstone-app
    spec:
      containers:
        - name: app
          image: REGISTRY_IP:5000/capstone-app:1.0
          ports:
            - containerPort: 5000
          env:
            - name: OWNER
              value: "OWNER_ID"
            - name: TOKEN
              value: "TOKEN_VALUE"
          readinessProbe:
            httpGet: { path: /health, port: 5000 }
            initialDelaySeconds: 3
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: /health, port: 5000 }
            initialDelaySeconds: 10
            periodSeconds: 10
          resources:
            requests: { cpu: 50m, memory: 48Mi }
            limits: { cpu: 250m, memory: 128Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: capstone-app
spec:
  type: NodePort
  selector:
    app: capstone-app
  ports:
    - port: 80
      targetPort: 5000
      nodePort: 30080
KY
  cat > "$B/ansible/baseline.yml" <<'AY'
---
- name: Capstone baseline (must be idempotent)
  hosts: localhost
  connection: local
  become: true
  vars:
    swap_mb: 2048
    install_docker: false
  tasks:
    - name: Refresh apt cache (not counted as a change)
      ansible.builtin.apt:
        update_cache: true
        cache_valid_time: 3600
      changed_when: false
    - name: Base tools
      ansible.builtin.apt:
        name: [git, curl, jq, unzip]
        state: present
    - name: CI tools (Docker and Python venv)
      ansible.builtin.apt:
        name: [docker.io, python3-venv]
        state: present
      when: install_docker | bool
    - name: Docker service enabled and started
      ansible.builtin.service:
        name: docker
        state: started
        enabled: true
      when: install_docker | bool
    - name: Create swap file
      ansible.builtin.command: "fallocate -l {{ swap_mb }}M /swapfile"
      args:
        creates: /swapfile
    - name: Swap file permissions
      ansible.builtin.file:
        path: /swapfile
        owner: root
        group: root
        mode: "0600"
    - name: Format swap file
      ansible.builtin.shell: "blkid -t TYPE=swap /swapfile >/dev/null 2>&1 || (mkswap /swapfile && echo formatted)"
      register: fmt
      changed_when: "'formatted' in fmt.stdout"
    - name: Enable swap
      ansible.builtin.shell: "swapon --show=NAME --noheadings | grep -qx /swapfile || (swapon /swapfile && echo enabled)"
      register: son
      changed_when: "'enabled' in son.stdout"
    - name: Persist swap in fstab
      ansible.builtin.lineinfile:
        path: /etc/fstab
        line: "/swapfile none swap sw 0 0"
    - name: Marker file proving Ansible managed this server
      ansible.builtin.copy:
        dest: /etc/capstone-baseline.txt
        content: "managed-by=ansible\nswap_mb={{ swap_mb }}\n"
        mode: "0644"
AY
  cat > "$B/bootstrap.sh" <<'BOOT_EOF'
#!/bin/bash
# usage: bootstrap.sh ROLE REG_IP CLOUD OWNER TOKEN     (runs once, as root, from user-data)
set -euo pipefail
ROLE="$1"; REG_IP="$2"; CLOUD="$3"; OWNER="$4"; TOKEN="$5"
exec >> /var/log/capstone-bootstrap.log 2>&1
set -x
export DEBIAN_FRONTEND=noninteractive
echo "$ROLE" > /etc/capstone-role
apt-get update -y
apt-get install -y ansible-core
DOCKER=false
if [ "$ROLE" = "ci" ]; then DOCKER=true; fi
ansible-playbook -c local -i localhost, -e install_docker=$DOCKER /opt/capstone/ansible/baseline.yml
if [ "$CLOUD" = "aws" ]; then apt-get install -y awscli || snap install aws-cli --classic; fi

if [ "$ROLE" = "ci" ]; then
  cd /opt/capstone
  docker run -d --name registry --restart=always -p 5000:5000 -v registrydata:/var/lib/registry registry:2
  sleep 5
  for v in 1.0 2.0; do
    docker build -t "localhost:5000/capstone-app:$v" --build-arg "APP_VERSION=$v" .
    docker push "localhost:5000/capstone-app:$v"
  done
  apt-get install -y openjdk-21-jre fontconfig
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL -o /etc/apt/keyrings/jenkins-keyring.asc https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key
  echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" > /etc/apt/sources.list.d/jenkins.list
  apt-get update -y
  apt-get install -y jenkins
  usermod -aG docker jenkins
  mkdir -p /etc/systemd/system/jenkins.service.d
  printf '[Service]\nEnvironment="JAVA_OPTS=-Djava.awt.headless=true -Xmx512m"\n' > /etc/systemd/system/jenkins.service.d/override.conf
  systemctl daemon-reload
  systemctl enable jenkins
  systemctl restart jenkins
fi

if [ "$ROLE" = "k8s" ]; then
  mkdir -p /etc/rancher/k3s
  cat > /etc/rancher/k3s/registries.yaml <<REG_EOF
mirrors:
  "$REG_IP:5000":
    endpoint:
      - "http://$REG_IP:5000"
REG_EOF
  sed -i "s/REGISTRY_IP/$REG_IP/; s/OWNER_ID/$OWNER/; s/TOKEN_VALUE/$TOKEN/" /opt/capstone/k8s/deployment.yaml
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --disable traefik" sh -
  for i in $(seq 1 60); do k3s kubectl get nodes 2>/dev/null | grep -q ' Ready' && break; sleep 5; done
fi
touch /var/lib/capstone-ready
BOOT_EOF
  chmod +x "$B/bootstrap.sh"
  tar czf "$WORK/bundle.tgz" -C "$B" .
  base64 -w 76 "$WORK/bundle.tgz" > "$WORK/bundle.b64"
}

make_userdata() { # make_userdata ROLE OUTFILE   (user-data = a shell script that unpacks the bundle)
  local role=$1 out=$2
  {
    echo '#!/bin/bash'
    echo 'mkdir -p /opt/capstone'
    echo "cat > /tmp/bundle.b64 <<'B64'"
    cat "$WORK/bundle.b64"
    echo 'B64'
    echo 'base64 -d /tmp/bundle.b64 | tar xz -C /opt/capstone'
    echo "bash /opt/capstone/bootstrap.sh $role $REG_IP $CLOUD $STUDENT_ID $TOKEN"
  } > "$out"
  local size; size=$(stat -c %s "$out")
  [ "$size" -lt "$USERDATA_MAX" ] || die "user-data is $size bytes (limit $USERDATA_MAX)"
  ok "user-data for $role: $size bytes"
}


phase_export() { # writes a Git-ready copy of the app (Mission 1: you push it to YOUR GitHub)
  make_bundle
  local dst="$HOME/capstone-app-$STUDENT_ID"; mkdir -p "$dst"; cp -a "$WORK/bundle/." "$dst/"
  printf '.venv/\n__pycache__/\n.pytest_cache/\n*.pyc\n' > "$dst/.gitignore"
  printf '# capstone-app (%s)\n\nDemo project from the DevOps bootcamp capstone. Not client work.\n' "$STUDENT_ID" > "$dst/README.md"
  ok "Git-ready folder: $dst"
}

need_my_ip() {
  [[ "$MY_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Set MY_IP to your public IP (open https://ifconfig.me in YOUR browser), e.g.: export MY_IP=203.0.113.7"
  [ "$MY_IP" != "0.0.0.0" ] || die "MY_IP must be your own address, never 0.0.0.0"
}

# =============================== AWS specifics ==============================
CLOUD=aws
REGION="${REGION:-ap-south-1}"             # keep the console and this script in the same region
export AWS_DEFAULT_REGION="$REGION" AWS_PAGER=""
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}" # must be Free-tier eligible in YOUR account
USERDATA_MAX=15500                         # EC2 user-data limit is 16 KB

usage() {
cat <<USAGE
Capstone (AWS)  -  usage:  ./capstone-aws.sh <phase> [args]

  Set these first:  export STUDENT_ID=iqbal01  MY_IP=<your public IP>  EMAIL=<you@mail>
  Optional:         export REGION=ap-south-1  INSTANCE_TYPE=t3.micro

  all        check, network, identity, compute, wait, monitor, status (about 15 min)
  check      login, region, instance type and input checks (nothing is created)
  network    VPC, subnet, internet gateway, route table, security group (least privilege)
  identity   IAM role + instance profile (SSM access), SecureString parameter
  compute    two Ubuntu 24.04 instances (ci = Jenkins + registry, k8s = K3s), Ansible baseline
  wait       wait until both servers finish their bootstrap
  monitor    SNS topic + CloudWatch CPU alarm
  status     URLs and where to click in the console
  run   ci|k8s "<command>"     run a shell command on a server (Systems Manager, no SSH)
  kube  <kubectl arguments>    run kubectl on the k8s server
  ansible ci|k8s               re-run the Ansible baseline and show the recap
  load                         6 minutes of CPU load on the k8s server (alarm test)
  verify     automatic check of the whole capstone (prints your score and token)
  export     write a Git-ready copy of the app to ~/capstone-app-<id> (Mission 1)
  secret [read|write]          read the secret with the server identity, or try to write it (must fail)
  report     value-stream report (lead time, flow efficiency)
USAGE
}

tspec() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=project,Value=capstone},{Key=owner,Value=$STUDENT_ID}]"; }

find_instance() { # find_instance ROLE -> instance id (running/pending/stopped)
  aws ec2 describe-instances --filters "Name=tag:owner,Values=$STUDENT_ID" "Name=tag:role,Values=$1" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId | [0]' --output text 2>/dev/null
}

remote() { # remote ROLE "command"  (Systems Manager Run Command: no open SSH port required)
  local id cid st i
  id=$(find_instance "$1"); [ -n "$id" ] && [ "$id" != None ] || die "No $1 instance found. Run compute first."
  cid=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
        --parameters "$(jq -n --arg c "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; $2" '{commands:[$c]}')" \
        --query Command.CommandId --output text) || return 1
  for i in $(seq 1 100); do
    st=$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query Status --output text 2>/dev/null)
    case "$st" in Success|Failed|Cancelled|TimedOut) break;; esac; sleep 3
  done
  aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" --query '[StandardOutputContent,StandardErrorContent]' --output text
}

set_names() { ROLE_NAME="$P-ec2-role"; PROFILE="$P-ec2-profile"; PARAM="/capstone/$STUDENT_ID/db-password"; }

phase_check() {
  need aws; need jq; need curl
  aws sts get-caller-identity >/dev/null 2>&1 || die "Not signed in. Open AWS CloudShell from the console toolbar."
  need_my_ip
  local elig; elig=$(aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true \
        --query 'InstanceTypes[].InstanceType' --output text 2>/dev/null)
  if ! echo " $elig " | grep -q " $INSTANCE_TYPE "; then
    [ "${CONFIRM_PAID:-no}" = yes ] || die "$INSTANCE_TYPE is not free-tier eligible for your account. Eligible types here: $elig . Pick one (export INSTANCE_TYPE=...) or accept the cost (export CONFIRM_PAID=yes)."
  fi
  ok "Account $(aws sts get-caller-identity --query Account --output text)  Region: $REGION  Type: $INSTANCE_TYPE"
  warn "Check Billing > Free Tier before you start. Public IPv4 addresses and EBS volumes can cost cents per hour."
}

phase_network() {
  need_my_ip
  local vpc igw sub rt sg
  vpc=$(aws ec2 create-vpc --cidr-block 10.50.0.0/16 --tag-specifications "$(tspec vpc "$P-vpc")" --query Vpc.VpcId --output text) || die "VPC failed"
  aws ec2 modify-vpc-attribute --vpc-id "$vpc" --enable-dns-hostnames '{"Value":true}'
  igw=$(aws ec2 create-internet-gateway --tag-specifications "$(tspec internet-gateway "$P-igw")" --query InternetGateway.InternetGatewayId --output text)
  aws ec2 attach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc"
  sub=$(aws ec2 create-subnet --vpc-id "$vpc" --cidr-block 10.50.1.0/24 --tag-specifications "$(tspec subnet "$P-subnet")" --query Subnet.SubnetId --output text)
  aws ec2 modify-subnet-attribute --subnet-id "$sub" --map-public-ip-on-launch
  rt=$(aws ec2 create-route-table --vpc-id "$vpc" --tag-specifications "$(tspec route-table "$P-rt")" --query RouteTable.RouteTableId --output text)
  aws ec2 create-route --route-table-id "$rt" --destination-cidr-block 0.0.0.0/0 --gateway-id "$igw" >/dev/null
  aws ec2 associate-route-table --route-table-id "$rt" --subnet-id "$sub" >/dev/null
  sg=$(aws ec2 create-security-group --group-name "$P-sg" --description "capstone least privilege" --vpc-id "$vpc" \
        --tag-specifications "$(tspec security-group "$P-sg")" --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "$sg" --ip-permissions \
    "IpProtocol=tcp,FromPort=8080,ToPort=8080,IpRanges=[{CidrIp=$MY_IP/32,Description=jenkins-from-student}]" \
    "IpProtocol=tcp,FromPort=30080,ToPort=30080,IpRanges=[{CidrIp=$MY_IP/32,Description=app-from-student}]" \
    "IpProtocol=tcp,FromPort=5000,ToPort=5000,IpRanges=[{CidrIp=10.50.1.0/24,Description=registry-from-subnet}]" >/dev/null
  save VPC "$vpc"; save SUBNET "$sub"; save SG "$sg"
  ok "VPC $vpc, subnet $sub, security group $sg. There is NO SSH rule: servers are managed with Systems Manager."
}

phase_identity() {
  local trust="$WORK/trust.json" pol="$WORK/param-policy.json"
  cat > "$trust" <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
  cat > "$pol" <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["ssm:GetParameter"],"Resource":"arn:aws:ssm:$REGION:*:parameter/capstone/$STUDENT_ID/*"}]}
JSON
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "file://$trust" --tags Key=project,Value=capstone >/dev/null \
    && ok "IAM role $ROLE_NAME"
  aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name read-own-params --policy-document "file://$pol"
  aws iam create-instance-profile --instance-profile-name "$PROFILE" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE" --role-name "$ROLE_NAME"
  aws ssm get-parameter --name "$PARAM" >/dev/null 2>&1 || \
    aws ssm put-parameter --name "$PARAM" --type SecureString --value "$(openssl rand -base64 12)" --tags Key=project,Value=capstone >/dev/null
  ok "SecureString parameter $PARAM (role may read ONLY /capstone/$STUDENT_ID/*)"
  say "Waiting 15 s for IAM to propagate ..."; sleep 15
}

phase_compute() {
  make_bundle
  make_userdata ci "$WORK/ud-ci.sh"; make_userdata k8s "$WORK/ud-k8s.sh"
  local ami role ip id try extra=()
  ami=$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
        --query Parameter.Value --output text) || die "Cannot find the Ubuntu 24.04 AMI"
  case "$INSTANCE_TYPE" in t2.*|t3.*) extra=(--credit-specification CpuCredits=standard);; esac   # no surprise CPU-credit charges
  for role in ci k8s; do
    ip=$REG_IP; [ "$role" = k8s ] && ip=$K8S_IP
    for try in 1 2 3 4 5 6; do
      id=$(aws ec2 run-instances --image-id "$ami" --instance-type "$INSTANCE_TYPE" --subnet-id "$SUBNET" --security-group-ids "$SG" \
        --private-ip-address "$ip" --iam-instance-profile "Name=$PROFILE" --user-data "file://$WORK/ud-$role.sh" \
        --metadata-options HttpTokens=required,HttpEndpoint=enabled \
        --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3,DeleteOnTermination=true}' \
        "${extra[@]}" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$P-$role},{Key=project,Value=capstone},{Key=owner,Value=$STUDENT_ID},{Key=role,Value=$role}]" "$(tspec volume "$P-$role-disk")" \
        --query 'Instances[0].InstanceId' --output text 2>/dev/null) && break
      say "instance profile not ready yet, retrying ($try/6) ..."; sleep 10
    done
    [ -n "${id:-}" ] || die "run-instances failed for $role"
    save "INST_$role" "$id"; ok "Instance $role = $id"
  done
  aws ec2 wait instance-running --instance-ids "$(find_instance ci)" "$(find_instance k8s)"
  ok "Both instances are running. They now install software on their own (about 8 to 12 minutes). Use: ./capstone-aws.sh wait"
}

phase_wait() {
  local role n out id
  for role in ci k8s; do
    id=$(find_instance $role); n=0
    while [ $n -lt 40 ]; do
      [ "$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$id" --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)" = Online ] && break
      n=$((n+1)); say "$role: waiting for the Systems Manager agent ($n/40) ..."; sleep 15
    done
    n=0
    while [ $n -lt 40 ]; do
      out=$(remote $role 'test -f /var/lib/capstone-ready && echo READY || echo WAIT' 2>/dev/null | grep -Eo 'READY|WAIT' | head -n1)
      [ "$out" = READY ] && { ok "$role server is ready"; break; }
      n=$((n+1)); say "$role still installing ($n/40) ..."; sleep 15
    done
    [ "$out" = READY ] || die "$role not ready. Read the log: ./capstone-aws.sh run $role 'tail -n 40 /var/log/capstone-bootstrap.log'"
  done
}

phase_monitor() {
  [ -n "$EMAIL" ] || die "Set EMAIL first: export EMAIL=you@example.com"
  local topic; topic=$(aws sns create-topic --name "$P-alerts" --tags Key=project,Value=capstone --query TopicArn --output text)
  aws sns subscribe --topic-arn "$topic" --protocol email --notification-endpoint "$EMAIL" >/dev/null
  ok "SNS topic $P-alerts. OPEN YOUR MAILBOX and click Confirm subscription."
  aws cloudwatch put-metric-alarm --alarm-name "$P-cpu-k8s" --alarm-description "Capstone: k8s server CPU above 70 percent" \
    --namespace AWS/EC2 --metric-name CPUUtilization --dimensions "Name=InstanceId,Value=$(find_instance k8s)" \
    --statistic Average --period 300 --evaluation-periods 1 --threshold 70 --comparison-operator GreaterThanThreshold \
    --alarm-actions "$topic" --tags Key=project,Value=capstone && ok "CloudWatch alarm $P-cpu-k8s (CPU > 70 percent over 5 minutes)"
}

phase_status() {
  local ci k8
  ci=$(aws ec2 describe-instances --instance-ids "$(find_instance ci)" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  k8=$(aws ec2 describe-instances --instance-ids "$(find_instance k8s)" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  echo; echo "Jenkins (from YOUR browser/IP only) : http://$ci:8080"
  echo "App on Kubernetes (NodePort)        : http://$k8:30080"
  echo "Console: EC2 > Instances (tag owner=$STUDENT_ID)  |  Parameter: $PARAM  |  Token: $TOKEN"
  echo "Jenkins unlock password : ./capstone-aws.sh run ci 'cat /var/lib/jenkins/secrets/initialAdminPassword'"
}

phase_ansible() { remote "$1" "ansible-playbook -c local -i localhost, -e install_docker=$([ "$1" = ci ] && echo true || echo false) /opt/capstone/ansible/baseline.yml" | tail -n 25; }

phase_secret() { # secret [read|write]  - uses the instance role, no access key anywhere
  if [ "${1:-read}" = write ]; then
    say "Trying to WRITE a parameter with the read-only role (must be refused)"
    remote ci "aws ssm put-parameter --name /capstone/$STUDENT_ID/not-allowed --value x --type String --region $REGION 2>&1 | tail -n 2"
  else
    say "Reading the secret with the instance role (only the length is shown)"
    remote ci "echo secret length: \$(aws ssm get-parameter --name $PARAM --with-decryption --region $REGION --query 'length(Parameter.Value)' --output text)"
  fi
}

phase_load() { say "Starting 6 minutes of CPU load on the k8s server"; remote k8s "nohup timeout 360 sh -c 'while :; do :; done' >/dev/null 2>&1 &"; ok "Load started. Watch CloudWatch > Alarms and your mailbox (5 to 10 minutes)."; }

phase_verify() {
  local pass=0 total=0 out r
  chk() { total=$((total+1)); if [ "$2" = "$3" ]; then pass=$((pass+1)); ok "$1"; else warn "FAIL: $1 (got '$2', expected '$3')"; fi; }
  out=$(aws ec2 describe-vpcs --filters "Name=tag:owner,Values=$STUDENT_ID" "Name=tag:project,Values=capstone" --query 'length(Vpcs)' --output text 2>/dev/null); chk "VPC exists and is tagged" "$out" "1"
  out=$(aws ec2 describe-security-groups --group-ids "${SG:-none}" --query "length(SecurityGroups[0].IpPermissions[?IpRanges[?CidrIp=='0.0.0.0/0']])" --output text 2>/dev/null)
  chk "No inbound rule is open to 0.0.0.0/0 (and no SSH rule)" "$out" "0"
  for r in ci k8s; do
    out=$(aws ec2 describe-instances --instance-ids "$(find_instance $r)" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null); chk "Instance $r is running" "$out" "running"
    out=$(aws ec2 describe-instances --instance-ids "$(find_instance $r)" --query 'Reservations[0].Instances[0].MetadataOptions.HttpTokens' --output text 2>/dev/null); chk "Instance $r enforces IMDSv2" "$out" "required"
    out=$(remote $r 'test -f /var/lib/capstone-ready && echo READY' 2>/dev/null | grep -o READY | head -n1); chk "Bootstrap finished on $r" "$out" "READY"
  done
  out=$(remote ci 'curl -s localhost:5000/v2/capstone-app/tags/list | jq -r ".tags|sort|join(\",\")"' | grep -Eo '[0-9][0-9,.]*' | head -n1)
  case "$out" in 1.0,2.0*) out=OK;; *) out="tags=$out";; esac; chk "Registry holds image tags 1.0 and 2.0" "$out" "OK"
  out=$(remote ci 'curl -s -o /dev/null -w "%{http_code}" localhost:8080/login' | grep -Eo '^[0-9]{3}|[0-9]{3}$' | head -n1); chk "Jenkins answers HTTP 200" "$out" "200"
  out=$(remote k8s 'kubectl get nodes --no-headers | grep -c " Ready"' | grep -Eo '^[0-9]+' | head -n1); chk "K3s node is Ready" "$out" "1"
  out=$(remote k8s 'curl -s localhost:30080/' | grep -o "token=$TOKEN" | head -n1); chk "App answers with your token on the NodePort" "$out" "token=$TOKEN"
  out=$(remote ci "aws ssm get-parameter --name $PARAM --with-decryption --region $REGION --query 'length(Parameter.Value)' --output text" | grep -Eo '^[0-9]+' | head -n1)
  [ "${out:-0}" -ge 8 ] 2>/dev/null && out=OK || out="no-read"; chk "Instance role reads the SecureString parameter" "$out" "OK"
  out=$(aws cloudwatch describe-alarms --alarm-names "$P-cpu-k8s" --query 'MetricAlarms[0].AlarmName' --output text 2>/dev/null); chk "CPU alarm exists" "$out" "$P-cpu-k8s"
  out=$(remote k8s 'ansible-playbook -c local -i localhost, -e install_docker=false /opt/capstone/ansible/baseline.yml' | grep -o 'changed=[0-9]*' | tail -n1); chk "Ansible re-run is idempotent (changed=0)" "$out" "changed=0"
  echo; echo "SCORE: $pass / $total      Token: $TOKEN      Student: $STUDENT_ID      $(date '+%F %T %Z')"
  echo "Take a screenshot of this screen for your evidence folder."
}

main() {
  local cmd="${1:-help}"; shift || true
  [ "$cmd" = help ] && { usage; exit 0; }
  need aws; init_workspace; set_names
  case "$cmd" in
    all)      for p in check network identity compute wait monitor status; do phase_run "$p" "phase_$p" || exit 1; done ;;
    check|network|identity|compute|wait|monitor|status|load|verify) phase_run "$cmd" "phase_$cmd" ;;
    export)   phase_run export phase_export ;;
    secret)   phase_secret "${1:-read}" ;;
    report)   phase_report ;;
    run)      remote "${1:?role ci|k8s}" "${2:?command}" ;;
    kube)     remote k8s "kubectl $(printf '%q ' "$@")" ;;
    ansible)  phase_ansible "${1:?role ci|k8s}" ;;
    *)        usage; exit 1 ;;
  esac
}
main "$@"
