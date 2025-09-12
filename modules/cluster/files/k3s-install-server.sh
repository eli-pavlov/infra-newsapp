#!/bin/bash
# K3s SERVER install, tooling, secret generation, ingress-nginx install,
# and Argo CD bootstrapping.
# Converted for Oracle Linux 9 (dnf-based) — no other behaviour changes.
set -euo pipefail

# Simpler robust logging to avoid SIGPIPE from tee|logger pipeline
exec > /var/log/cloud-init-output.log 2>&1

# Optional: enable command tracing and report failing command
set -x
trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR

# --- Vars injected by Terraform (these are expanded by templatefile) ---
T_K3S_VERSION="${T_K3S_VERSION}"
T_K3S_TOKEN="${T_K3S_TOKEN}"
T_DB_USER="${T_DB_USER}"
T_DB_NAME_DEV="${T_DB_NAME_DEV}"
T_DB_NAME_PROD="${T_DB_NAME_PROD}"
T_DB_SERVICE_NAME_DEV="${T_DB_SERVICE_NAME_DEV}"
T_DB_SERVICE_NAME_PROD="${T_DB_SERVICE_NAME_PROD}"
T_MANIFESTS_REPO_URL="${T_MANIFESTS_REPO_URL}"
T_EXPECTED_NODE_COUNT="${T_EXPECTED_NODE_COUNT}"
T_PRIVATE_LB_IP="${T_PRIVATE_LB_IP}"

install_base_tools() {
  echo "Installing base packages (dnf)..."
  # Refresh metadata and install minimal tools. Keep changes minimal (no full distro upgrade).
  dnf makecache --refresh -y || true
  dnf update -y || true
  dnf install -y curl jq git || true
}

# Ensure firewalld is disabled for k3s networking (original script choice)
systemctl disable firewalld --now || true

get_private_ip() {
  echo "Fetching instance private IP from metadata (OCI metadata endpoint)..."
  # OCI metadata path. Header Authorization shown in original script — preserved.
  PRIVATE_IP=$(curl -s -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/vnics/ | jq -r '.[0].privateIp')
  if [ -z "$PRIVATE_IP" ] || [ "$PRIVATE_IP" = "null" ]; then
    echo "❌ Failed to fetch private IP."
    exit 1
  fi
  echo "✅ Instance private IP is $PRIVATE_IP"
}

install_k3s_server() {
  echo "Installing K3s server..."

  # Add TLS SANs for both the node's own IP and the private LB IP
  local PARAMS="--write-kubeconfig-mode 644 \
    --node-ip $PRIVATE_IP \
    --advertise-address $PRIVATE_IP \
    --disable traefik \
    --tls-san $PRIVATE_IP \
    --tls-san ${T_PRIVATE_LB_IP} \
    --kubelet-arg=register-with-taints=node-role.kubernetes.io/control-plane=true:NoSchedule"

  export INSTALL_K3S_EXEC="$PARAMS"
  export K3S_TOKEN="$T_K3S_TOKEN"
  export INSTALL_K3S_VERSION="$T_K3S_VERSION"

  # Use upstream installer (works on OL9)
  curl -sfL https://get.k3s.io | sh -

  echo "Waiting for K3s server node to be Ready..."
  # Wait until kubectl from k3s observes this node Ready (safeguarded loop)
  local retry=0
  until /usr/local/bin/kubectl get node "$(hostname)" 2>/dev/null | grep -q 'Ready'; do
    sleep 5
    retry=$((retry+1))
    if [ "$retry" -gt 180 ]; then
      echo "Timed out waiting for node Ready after ~15 minutes"
      /usr/local/bin/kubectl get nodes || true
      exit 1
    fi
  done
  echo "✅ K3s server node is running."
}

wait_for_kubeconfig_and_api() {
  echo "Waiting for kubeconfig and API to be fully ready..."
  local timeout=120
  local start_time
  start_time=$(date +%s)
  while true; do
    if [ ! -f /etc/rancher/k3s/k3s.yaml ]; then
      echo "Waiting for kubeconfig file to be created..."
      sleep 5
      continue
    fi
    if /usr/local/bin/kubectl get nodes 2>/dev/null | grep -q 'Ready'; then
      if /usr/local/bin/kubectl get pods -n kube-system 2>/dev/null | grep -qE '(etcd|coredns|kube-proxy|kube-scheduler|kube-controller)'; then
        echo "✅ Kubeconfig and API are ready."
        break
      fi
    fi
    local elapsed_time=$(( $(date +%s) - start_time ))
    if [ "$elapsed_time" -gt "$timeout" ]; then
      echo "❌ Timed out waiting for kubeconfig and API readiness."
      /usr/local/bin/kubectl cluster-info || true
      exit 1
    fi
    echo "($elapsed_time/$timeout s) Waiting for kubeconfig and API readiness..."
    sleep 5
  done
}

wait_for_all_nodes() {
  echo "Waiting for all $T_EXPECTED_NODE_COUNT nodes to join and become Ready..."
  local timeout=900
  local start_time; start_time=$(date +%s)
  while true; do
    local ready_nodes
    ready_nodes=$(/usr/local/bin/kubectl get nodes --no-headers 2>/dev/null \
      | awk '{print $2}' | grep -Ec '^Ready(,SchedulingDisabled)?$' || true)
    if [ "$ready_nodes" -eq "$T_EXPECTED_NODE_COUNT" ]; then
      echo "✅ All $T_EXPECTED_NODE_COUNT nodes are Ready. Proceeding."
      break
    fi
    local elapsed_time=$(( $(date +%s) - start_time ))
    if [ "$elapsed_time" -gt "$timeout" ]; then
      echo "❌ Timed out waiting for all nodes to become Ready."
      /usr/local/bin/kubectl get nodes || true
      exit 1
    fi
    echo "($elapsed_time/$timeout s) Currently $ready_nodes/$T_EXPECTED_NODE_COUNT nodes are Ready. Waiting..."
    sleep 15
  done
}

# ---------------------------------------------------------
# Create systemd oneshot bootstrap unit + env + helper script
# ---------------------------------------------------------
install_and_enable_bootstrap_unit() {
  echo "Installing systemd oneshot for long bootstrap (30min timeout)..."

  # 1) Write an env file with the Terraform-injected variables expanded now.
  #    This file will be sourced by the bootstrap script at runtime.
  cat > /etc/bootstrap-env <<EOF
export T_K3S_VERSION="${T_K3S_VERSION}"
export T_K3S_TOKEN="${T_K3S_TOKEN}"
export T_DB_USER="${T_DB_USER}"
export T_DB_NAME_DEV="${T_DB_NAME_DEV}"
export T_DB_NAME_PROD="${T_DB_NAME_PROD}"
export T_DB_SERVICE_NAME_DEV="${T_DB_SERVICE_NAME_DEV}"
export T_DB_SERVICE_NAME_PROD="${T_DB_SERVICE_NAME_PROD}"
export T_MANIFESTS_REPO_URL="${T_MANIFESTS_REPO_URL}"
export T_EXPECTED_NODE_COUNT="${T_EXPECTED_NODE_COUNT}"
export T_PRIVATE_LB_IP="${T_PRIVATE_LB_IP}"
EOF
  chmod 600 /etc/bootstrap-env
  chown root:root /etc/bootstrap-env
  # Restore SELinux context if SELinux is enabled
  if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null || echo Permissive)" != "Disabled" ]; then
    restorecon -v /etc/bootstrap-env || true
  fi

  # 2) Write the bootstrap script. Use a single-quoted heredoc so variables are
  #    evaluated at runtime by the bootstrap script, not now by cloud-init/templatefile.
  cat > /usr/local/bin/bootstrap-newsapp.sh <<'BOOTSTRAP'
#!/bin/bash
set -euo pipefail
exec >> /var/log/bootstrap-newsapp.log 2>&1

# Source the env exported at provisioning time (if present)
if [ -f /etc/bootstrap-env ]; then
  # shellcheck disable=SC1091
  source /etc/bootstrap-env
fi

# Fallback: ensure kubectl is available at /usr/local/bin/kubectl
if [ ! -x /usr/local/bin/kubectl ]; then
  if command -v kubectl >/dev/null 2>&1; then
    ln -sf "$(command -v kubectl)" /usr/local/bin/kubectl
  fi
fi

# restore SELinux context on the script if needed
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null || echo Permissive)" != "Disabled" ]; then
  restorecon -v /usr/local/bin/bootstrap-newsapp.sh || true
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

wait_for_kubeconfig_and_api() {
  echo "Waiting for kubeconfig and API to be fully ready..."
  local timeout=120
  local start_time
  start_time=$(date +%s)
  while true; do
    if [ ! -f "${KUBECONFIG}" ]; then
      echo "Waiting for kubeconfig file to be created..."
      sleep 5
      continue
    fi
    if /usr/local/bin/kubectl get nodes 2>/dev/null | grep -q 'Ready'; then
      if /usr/local/bin/kubectl get pods -n kube-system 2>/dev/null | grep -qE '(etcd|coredns|kube-proxy|kube-scheduler|kube-controller)'; then
        echo "Kubeconfig and API are ready."
        break
      fi
    fi
    local elapsed_time=$(( $(date +%s) - start_time ))
    if [ "$elapsed_time" -gt "$timeout" ]; then
      echo "Timed out waiting for kubeconfig and API readiness."
      /usr/local/bin/kubectl cluster-info || true
      exit 1
    fi
    sleep 5
  done
}

wait_for_all_nodes() {
  echo "Waiting for all ${T_EXPECTED_NODE_COUNT} nodes to join and become Ready..."
  local timeout=900
  local start_time; start_time=$(date +%s)
  while true; do
    local ready_nodes
    ready_nodes=$(/usr/local/bin/kubectl get nodes --no-headers 2>/dev/null \
      | awk '{print $2}' | grep -Ec '^Ready(,SchedulingDisabled)?$' || true)
    if [ "$ready_nodes" -eq "${T_EXPECTED_NODE_COUNT}" ]; then
      echo "All ${T_EXPECTED_NODE_COUNT} nodes are Ready."
      break
    fi
    local elapsed_time=$(( $(date +%s) - start_time ))
    if [ "$elapsed_time" -gt "$timeout" ]; then
      echo "Timed out waiting for all nodes to become Ready."
      /usr/local/bin/kubectl get nodes || true
      exit 1
    fi
    echo "Currently ${ready_nodes}/${T_EXPECTED_NODE_COUNT} nodes are Ready. Waiting..."
    sleep 15
  done
}

install_helm() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  if ! command -v helm &> /dev/null; then
    echo "Installing Helm..."
    curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 /tmp/get_helm.sh
    /tmp/get_helm.sh
    rm -f /tmp/get_helm.sh
  fi
}

install_ingress_nginx() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo "Installing ingress-nginx via Helm..."
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
  helm repo update || true
  /usr/local/bin/kubectl create namespace ingress-nginx || true
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --set controller.kind=DaemonSet \
    --set controller.service.type=NodePort \
    --set controller.service.nodePorts.http=30080 \
    --set controller.service.nodePorts.https=30443 \
    --set controller.service.externalTrafficPolicy=Local \
    --set controller.nodeSelector.role=application \
    --set controller.ingressClassResource.name=nginx \
    --set controller.ingressClassByName=true \
    --wait --timeout 5m || true
  /usr/local/bin/kubectl -n ingress-nginx rollout status ds/ingress-nginx-controller --timeout=5m || true
}

install_argo_cd() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo "Installing Argo CD..."
  /usr/local/bin/kubectl create namespace argocd || true
  /usr/local/bin/kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml || true

  for d in argocd-server argocd-repo-server argocd-dex-server; do
    /usr/local/bin/kubectl -n argocd patch deployment "$d" --type='json' -p='[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}]' || true
  done

  /usr/local/bin/kubectl -n argocd patch statefulset argocd-application-controller --type='json' -p='[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}]' || true

  /usr/local/bin/kubectl -n argocd wait --for=condition=Available deployments --all --timeout=5m || true
  /usr/local/bin/kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=5m || true
}

# Simple non-blocking delay before writing secrets (as requested)
generate_secrets_and_credentials() {
  echo "Sleeping 30 seconds to allow Argo CD to initialize (no blocking wait for secret)..."
  sleep 30

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo "Generating credentials and Kubernetes secrets..."
  DB_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)

  # Try to read Argo admin password (may be empty if Argo not ready)
  ARGO_PASSWORD=$(/usr/local/bin/kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || true)

  cat <<EOF > /root/credentials.txt
# --- Argo CD Admin Credentials ---
Username: admin
Password: $ARGO_PASSWORD

# --- PostgreSQL Database Credentials ---
Username: $T_DB_USER
Password: $DB_PASSWORD
EOF
  chmod 600 /root/credentials.txt

  for ns in default development; do
    /usr/local/bin/kubectl create namespace "$ns" --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f - || true
    /usr/local/bin/kubectl -n "$ns" create secret generic postgres-credentials \
      --from-literal=POSTGRES_USER="$T_DB_USER" \
      --from-literal=POSTGRES_PASSWORD="$DB_PASSWORD" \
      --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f - || true
  done

  DB_URI_DEV="postgresql://$T_DB_USER:$DB_PASSWORD@$T_DB_SERVICE_NAME_DEV-client.development.svc.cluster.local:5432/$T_DB_NAME_DEV"
  /usr/local/bin/kubectl -n development create secret generic backend-db-connection \
    --from-literal=DB_URI="$DB_URI_DEV" --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f - || true

  DB_URI_PROD="postgresql://$T_DB_USER:$DB_PASSWORD@$T_DB_SERVICE_NAME_PROD-client.default.svc.cluster.local:5432/$T_DB_NAME_PROD"
  /usr/local/bin/kubectl -n default create secret generic backend-db-connection \
    --from-literal=DB_URI="$DB_URI_PROD" --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f - || true

  echo "Credentials and secrets created (if API available)."
}

bootstrap_argocd_apps() {
  echo "Bootstrapping Argo CD with applications from manifest repo..."
  rm -rf /tmp/manifests || true

  if [ -n "$T_MANIFESTS_REPO_URL" ]; then
    git clone --depth=1 "$T_MANIFESTS_REPO_URL" /tmp/manifests || (sleep 5 && git clone "$T_MANIFESTS_REPO_URL" /tmp/manifests) || true

    # DEV
    [ -f /tmp/manifests/clusters/dev/apps/project.yaml ] && /usr/local/bin/kubectl apply -f /tmp/manifests/clusters/dev/apps/project.yaml || true
    [ -f /tmp/manifests/clusters/dev/apps/stack.yaml ]   && /usr/local/bin/kubectl apply -f /tmp/manifests/clusters/dev/apps/stack.yaml   || true

    # PROD
    [ -f /tmp/manifests/clusters/prod/apps/project.yaml ] && /usr/local/bin/kubectl apply -f /tmp/manifests/clusters/prod/apps/project.yaml || true
    [ -f /tmp/manifests/clusters/prod/apps/stack.yaml ]   && /usr/local/bin/kubectl apply -f /tmp/manifests/clusters/prod/apps/stack.yaml   || true
  fi

  echo "Argo CD applications applied (if manifests existed)."
}

bootstrap_main() {
  wait_for_kubeconfig_and_api
  wait_for_all_nodes
  install_helm
  install_ingress_nginx
  install_argo_cd
  # Non-blocking secrets creation
  generate_secrets_and_credentials
  # Try to apply manifests (can succeed even if Argo CD hasn't finished)
  bootstrap_argocd_apps
}

# Run heavy work
bootstrap_main
BOOTSTRAP

  chmod 700 /usr/local/bin/bootstrap-newsapp.sh
  chown root:root /usr/local/bin/bootstrap-newsapp.sh
  if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null || echo Permissive)" != "Disabled" ]; then
    restorecon -v /usr/local/bin/bootstrap-newsapp.sh || true
  fi

  # 3) Create systemd unit (30min timeout)
  cat > /etc/systemd/system/bootstrap-newsapp.service <<'UNIT'
[Unit]
Description=Bootstrap newsapp (k3s/ingress/argocd/secrets)
After=network-online.target k3s.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/bootstrap-newsapp.sh
TimeoutStartSec=30min
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

  # 4) reload & enable+start the unit
  systemctl daemon-reload
  systemctl enable --now bootstrap-newsapp.service || systemctl start bootstrap-newsapp.service || true

  echo "bootstrap-newsapp.service installed and started. Follow logs with: sudo journalctl -u bootstrap-newsapp -f"
}

# ----------------------------
# Main (fast cloud-init path)
# ----------------------------
main() {
  install_base_tools
  get_private_ip
  install_k3s_server
  # quick checks to ensure kubeconfig exists before we hand off to systemd oneshot
  wait_for_kubeconfig_and_api
  wait_for_all_nodes

  # Install & start heavy bootstrap as a systemd oneshot (so cloud-init exits quickly)
  install_and_enable_bootstrap_unit

  # Do NOT perform long helm/argocd/secrets work here: the oneshot will do that.
}

main "$@"
