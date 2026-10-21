#!/usr/bin/env bash
# =============================================================================
# capstone-azure.sh  -  DevOps Bootcamp Capstone (AZ-400 + AZ-104), Azure edition
# Run in Azure Cloud Shell (Bash). Free-account sizes. One script, many phases.
# Cleanup: cleanup-azure.sh   (always run it before you leave)
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

# ============================== Azure specifics =============================
CLOUD=azure
LOCATION="${LOCATION:-southeastasia}"      # choose a region where your free-account VM size is offered
VM_SIZE="${VM_SIZE:-Standard_B1s}"         # free-account size (750 h/month for 12 months)
USERDATA_MAX=60000                         # custom-data limit is 64 KB

usage() {
cat <<USAGE
Capstone (Azure)  -  usage:  ./capstone-azure.sh <phase> [args]

  Set these first:  export STUDENT_ID=iqbal01  MY_IP=<your public IP>  EMAIL=<you@mail>
  Optional:         export LOCATION=southeastasia  VM_SIZE=Standard_B1s

  all        check, network, compute, wait, identity, monitor, status (about 15 min)
  check      login, region, VM size and input checks (nothing is created)
  network    resource group, VNet, subnet, NSG with least-privilege rules
  compute    two Ubuntu 24.04 VMs (ci = Jenkins + registry, k8s = K3s), Ansible baseline
  wait       wait until both servers finish their bootstrap
  identity   Key Vault (RBAC), secret, managed-identity role, resource lock, policy
  monitor    action group + CPU alert rule
  status     URLs and where to click in the portal
  run   ci|k8s "<command>"     run a shell command on a server (no SSH needed)
  kube  <kubectl arguments>    run kubectl on the k8s server
  ansible ci|k8s               re-run the Ansible baseline and show the recap
  load                         6 minutes of CPU load on the k8s server (alert test)
  verify     automatic check of the whole capstone (prints your score and token)
  export     write a Git-ready copy of the app to ~/capstone-app-<id> (Mission 1)
  secret [read|write]          read the secret with the server identity, or try to write it (must fail)
  report     value-stream report (lead time, flow efficiency)
USAGE
}

az_vmname() { case "$1" in ci) echo "$P-ci";; k8s) echo "$P-k8s";; *) die "role must be ci or k8s";; esac; }

remote() { # remote ROLE "command"  (Azure Run Command: no open SSH port required)
  az vm run-command invoke -g "$RG" -n "$(az_vmname "$1")" --command-id RunShellScript \
    --scripts "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; $2" --query 'value[0].message' -o tsv
}

set_names() {
  RG="rg-$P"; VNET="vnet-$P"; SUBNET="snet-app"; NSG="nsg-$P"
  if [ -z "${SUFFIX:-}" ]; then SUFFIX=$(printf '%s' "$TOKEN" | cut -c1-5); save SUFFIX "$SUFFIX"; fi
  KV="kv${STUDENT_ID}${SUFFIX}"
}

phase_check() {
  need az; need jq; need curl
  az account show >/dev/null 2>&1 || die "Not signed in. Open Azure Cloud Shell (Bash) from the portal; it signs you in."
  need_my_ip
  local sku; sku=$(az vm list-skus --location "$LOCATION" --size "$VM_SIZE" --resource-type virtualMachines \
        --query '[?length(restrictions)==`0`].name | [0]' -o tsv 2>/dev/null)
  [ -n "$sku" ] || die "$VM_SIZE is not available to you in $LOCATION. Try another LOCATION or VM_SIZE (B2ats_v2, B2pts_v2)."
  ok "Subscription: $(az account show --query name -o tsv)  Region: $LOCATION  Size: $VM_SIZE"
  warn "Free account: check Cost Management + Billing > Free services. Public IPs and disks can cost cents per hour."
  for ns in Microsoft.Compute Microsoft.Network Microsoft.KeyVault Microsoft.Insights Microsoft.PolicyInsights; do
    az provider register --namespace "$ns" >/dev/null 2>&1
  done
  ok "Resource providers registering in the background"
}

phase_network() {
  need_my_ip
  az group create -n "$RG" -l "$LOCATION" --tags project=capstone owner="$STUDENT_ID" -o none && ok "Resource group $RG"
  az network vnet create -g "$RG" -n "$VNET" --address-prefix 10.50.0.0/16 \
     --subnet-name "$SUBNET" --subnet-prefix 10.50.1.0/24 --tags project=capstone -o none && ok "VNet $VNET"
  az network nsg create -g "$RG" -n "$NSG" --tags project=capstone -o none
  az network nsg rule create -g "$RG" --nsg-name "$NSG" -n allow-jenkins-from-me --priority 100 --direction Inbound \
     --access Allow --protocol Tcp --source-address-prefixes "$MY_IP/32" --destination-port-ranges 8080 -o none
  az network nsg rule create -g "$RG" --nsg-name "$NSG" -n allow-app-from-me --priority 110 --direction Inbound \
     --access Allow --protocol Tcp --source-address-prefixes "$MY_IP/32" --destination-port-ranges 30080 -o none
  az network nsg rule create -g "$RG" --nsg-name "$NSG" -n allow-registry-from-subnet --priority 120 --direction Inbound \
     --access Allow --protocol Tcp --source-address-prefixes 10.50.1.0/24 --destination-port-ranges 5000 -o none
  az network vnet subnet update -g "$RG" --vnet-name "$VNET" -n "$SUBNET" --network-security-group "$NSG" -o none
  ok "NSG $NSG attached to the subnet. There is NO SSH rule: servers are managed with Run Command."
}

phase_compute() {
  make_bundle
  make_userdata ci "$WORK/ud-ci.sh"; make_userdata k8s "$WORK/ud-k8s.sh"
  local role ip
  for role in ci k8s; do
    ip=$REG_IP; [ "$role" = k8s ] && ip=$K8S_IP
    az vm create -g "$RG" -n "$(az_vmname $role)" --image Canonical:ubuntu-24_04-lts:server:latest --size "$VM_SIZE" \
      --admin-username azureuser --generate-ssh-keys --vnet-name "$VNET" --subnet "$SUBNET" \
      --private-ip-address "$ip" --public-ip-sku Standard --public-ip-address "$(az_vmname $role)-pip" --nsg "" \
      --assign-identity '[system]' --custom-data "$WORK/ud-$role.sh" \
      --storage-sku Premium_LRS --os-disk-size-gb 64 --tags project=capstone owner="$STUDENT_ID" role="$role" \
      --no-wait -o none || die "az vm create failed for $role"
  done
  for role in ci k8s; do az vm wait -g "$RG" -n "$(az_vmname $role)" --created; done
  ok "Both VMs exist. They now install software on their own (about 8 to 12 minutes). Use: ./capstone-azure.sh wait"
}

phase_wait() {
  local role n=0 out
  for role in ci k8s; do
    n=0
    while [ $n -lt 30 ]; do
      out=$(remote $role 'test -f /var/lib/capstone-ready && echo READY || echo WAIT' 2>/dev/null | tr -d '\r' | grep -Eo 'READY|WAIT' | head -n1)
      [ "$out" = READY ] && { ok "$role server is ready"; break; }
      n=$((n+1)); say "$role still installing ($n/30) ..."; sleep 20
    done
    [ "$out" = READY ] || die "$role not ready. Read the log: ./capstone-azure.sh run $role 'tail -n 40 /var/log/capstone-bootstrap.log'"
  done
}

phase_identity() {
  local me kvid vmpid t
  az keyvault create -g "$RG" -n "$KV" -l "$LOCATION" --enable-rbac-authorization true --retention-days 7 --tags project=capstone -o none \
     || die "Key Vault creation failed"
  kvid=$(az keyvault show -n "$KV" --query id -o tsv)
  me="${ME_OID:-$(az ad signed-in-user show --query id -o tsv 2>/dev/null)}"
  [ -n "$me" ] || die "Cannot read your object id. Set it manually: export ME_OID=<object id from Entra ID > Users>"
  az role assignment create --assignee-object-id "$me" --assignee-principal-type User \
     --role "Key Vault Secrets Officer" --scope "$kvid" -o none && ok "You: Key Vault Secrets Officer (scope = this vault only)"
  vmpid=$(az vm show -g "$RG" -n "$(az_vmname ci)" --query identity.principalId -o tsv)
  az role assignment create --assignee-object-id "$vmpid" --assignee-principal-type ServicePrincipal \
     --role "Key Vault Secrets User" --scope "$kvid" -o none && ok "CI VM managed identity: Key Vault Secrets User (read only)"
  for t in $(seq 1 12); do
    az keyvault secret set --vault-name "$KV" --name db-password --value "$(openssl rand -base64 12)" -o none 2>/dev/null && { ok "Secret db-password stored"; break; }
    say "waiting for role propagation ($t/12) ..."; sleep 15
  done
  az lock create --name lock-kv --lock-type CanNotDelete -g "$RG" --resource-name "$KV" \
     --resource-type Microsoft.KeyVault/vaults -o none && ok "CanNotDelete lock on the vault"
  az policy assignment create --name allowed-loc --display-name "Allowed locations (capstone)" \
     --policy e56962a6-4747-49cd-b67b-bf8b01975c4c --params "{\"listOfAllowedLocations\":{\"value\":[\"$LOCATION\"]}}" \
     --scope "$(az group show -n "$RG" --query id -o tsv)" -o none 2>/dev/null \
     && ok "Policy: only $LOCATION allowed in this resource group" || warn "Policy assignment skipped (optional)"
}

phase_monitor() {
  [ -n "$EMAIL" ] || die "Set EMAIL first: export EMAIL=you@example.com"
  local vmid; vmid=$(az vm show -g "$RG" -n "$(az_vmname k8s)" --query id -o tsv)
  az monitor action-group create -g "$RG" -n "ag-$P" --short-name capstone --action email student "$EMAIL" -o none \
     && ok "Action group ag-$P -> $EMAIL"
  az monitor metrics alert create -g "$RG" -n "alert-cpu-$P" --scopes "$vmid" --condition "avg Percentage CPU > 70" \
     --window-size 5m --evaluation-frequency 1m --action "ag-$P" --description "Capstone: k8s server CPU above 70 percent" -o none \
     && ok "Alert rule alert-cpu-$P (CPU > 70 percent for 5 minutes)"
}

phase_status() {
  local ci k8
  ci=$(az vm list-ip-addresses -g "$RG" -n "$(az_vmname ci)" --query '[0].virtualMachine.network.publicIpAddresses[0].ipAddress' -o tsv)
  k8=$(az vm list-ip-addresses -g "$RG" -n "$(az_vmname k8s)" --query '[0].virtualMachine.network.publicIpAddresses[0].ipAddress' -o tsv)
  echo; echo "Jenkins (from YOUR browser/IP only) : http://$ci:8080"
  echo "App on Kubernetes (NodePort)        : http://$k8:30080"
  echo "Portal: resource group  rg-$P  |  Key Vault: $KV  |  Token: $TOKEN"
  echo "Jenkins unlock password : ./capstone-azure.sh run ci 'cat /var/lib/jenkins/secrets/initialAdminPassword'"
}

phase_ansible() { remote "$1" "ansible-playbook -c local -i localhost, -e install_docker=$([ "$1" = ci ] && echo true || echo false) /opt/capstone/ansible/baseline.yml" | tail -n 25; }

phase_secret() { # secret [read|write]  - uses the VM managed identity, no password anywhere
  local tok="TOK=\$(curl -s -H Metadata:true 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' | jq -r .access_token);"
  if [ "${1:-read}" = write ]; then
    say "Trying to WRITE a secret with the read-only identity (must be refused)"
    remote ci "$tok curl -s -o /dev/null -w 'HTTP %{http_code}\n' -X PUT -H \"Authorization: Bearer \$TOK\" -H 'Content-Type: application/json' -d '{\"value\":\"x\"}' 'https://$KV.vault.azure.net/secrets/not-allowed?api-version=7.4'"
  else
    say "Reading the secret with the VM managed identity (only the length is shown)"
    remote ci "$tok echo secret length: \$(curl -s -H \"Authorization: Bearer \$TOK\" 'https://$KV.vault.azure.net/secrets/db-password?api-version=7.4' | jq -r '.value|length')"
  fi
}

phase_load() { say "Starting 6 minutes of CPU load on the k8s server"; remote k8s "nohup timeout 360 sh -c 'while :; do :; done' >/dev/null 2>&1 &"; ok "Load started. Watch Monitor > Alerts and your mailbox (5 to 10 minutes)."; }

phase_verify() {
  local pass=0 total=0 out
  chk() { total=$((total+1)); if [ "$2" = "$3" ]; then pass=$((pass+1)); ok "$1"; else warn "FAIL: $1 (got '$2', expected '$3')"; fi; }
  out=$(az group show -n "$RG" --query tags.project -o tsv 2>/dev/null);                    chk "Resource group exists and is tagged" "$out" "capstone"
  out=$(az network nsg rule list -g "$RG" --nsg-name "$NSG" --query "[?access=='Allow' && direction=='Inbound' && (sourceAddressPrefix=='*' || sourceAddressPrefix=='Internet')] | length(@)" -o tsv 2>/dev/null)
  chk "No inbound rule is open to the whole internet (and no SSH rule)" "$out" "0"
  for r in ci k8s; do
    out=$(az vm get-instance-view -g "$RG" -n "$(az_vmname $r)" --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus | [0]" -o tsv 2>/dev/null)
    chk "VM $r is running" "$out" "VM running"
    out=$(remote $r 'test -f /var/lib/capstone-ready && echo READY' 2>/dev/null | grep -o READY | head -n1); chk "Bootstrap finished on $r" "$out" "READY"
  done
  out=$(remote ci 'curl -s localhost:5000/v2/capstone-app/tags/list | jq -r ".tags|sort|join(\",\")"' | tr -d '\r' | grep -Eo '[0-9][0-9,.]*' | head -n1)
  case "$out" in 1.0,2.0*) out=OK;; *) out="tags=$out";; esac; chk "Registry holds image tags 1.0 and 2.0" "$out" "OK"
  out=$(remote ci 'curl -s -o /dev/null -w "%{http_code}" localhost:8080/login' | grep -Eo '^[0-9]{3}|[0-9]{3}$' | head -n1); chk "Jenkins answers HTTP 200" "$out" "200"
  out=$(remote k8s 'kubectl get nodes --no-headers | grep -c " Ready"' | grep -Eo '^[0-9]+' | head -n1); chk "K3s node is Ready" "$out" "1"
  out=$(remote k8s 'curl -s localhost:30080/' | grep -o "token=$TOKEN" | head -n1); chk "App answers with your token on the NodePort" "$out" "token=$TOKEN"
  out=$(remote ci "TOK=\$(curl -s -H Metadata:true 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' | jq -r .access_token); curl -s -H \"Authorization: Bearer \$TOK\" 'https://$KV.vault.azure.net/secrets/db-password?api-version=7.4' | jq -r '.value|length'" | grep -Eo '^[0-9]+' | head -n1)
  [ "${out:-0}" -ge 8 ] 2>/dev/null && out=OK || out="no-read"; chk "VM managed identity reads the Key Vault secret" "$out" "OK"
  out=$(az monitor metrics alert show -g "$RG" -n "alert-cpu-$P" --query name -o tsv 2>/dev/null);  chk "CPU alert rule exists" "$out" "alert-cpu-$P"
  out=$(remote k8s 'ansible-playbook -c local -i localhost, -e install_docker=false /opt/capstone/ansible/baseline.yml' | grep -o 'changed=[0-9]*' | tail -n1); chk "Ansible re-run is idempotent (changed=0)" "$out" "changed=0"
  echo; echo "SCORE: $pass / $total      Token: $TOKEN      Student: $STUDENT_ID      $(date '+%F %T %Z')"
  echo "Take a screenshot of this screen for your evidence folder."
}

main() {
  local cmd="${1:-help}"; shift || true
  [ "$cmd" = help ] && { usage; exit 0; }
  need az; init_workspace; set_names
  case "$cmd" in
    all)      for p in check network compute wait identity monitor status; do phase_run "$p" "phase_$p" || exit 1; done ;;
    check|network|compute|wait|identity|monitor|status|load|verify) phase_run "$cmd" "phase_$cmd" ;;
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
