#!/bin/bash
# K3s SERVER install, tooling, secret generation, ingress-nginx install,
# and Argo CD bootstrapping.
# Converted for Oracle Linux 9 (dnf-based) — adds robust waiting for kube-api/kubeconfig.
set -euo pipefail
exec > >(tee /var/log/cloud-init-output.log | logger -t user-data -s 2>/dev/console) 2>&1

# --- Vars injected by Terraform ---
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

# k3s kubeconfig path
K3S_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
KUBECTL="/usr/local/bin/kubectl"
HELM_BIN="/usr/local/bin/helm"

log() { printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }

install_base_tools() {
  log "Installing base packages (dnf)..."
  dnf makecache --refresh -y || true
  dnf install -y curl jq git || true
}

# Disable firewalld early (as in original)
systemctl disable firewalld --now || true

get_private_ip() {
  log "Fetching instance private IP from metadata (OCI metadata endpoint)..."
  PRIVATE_IP=$(curl -s -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/vnics/ | jq -r '.[0].privateIp')
  if [ -z "$PRIVATE_IP" ] || [ "$PRIVATE_IP" = "null" ]; then
    log "❌ Failed to fetch private IP."
    exit 1
  fi
  log "✅ Instance private IP is $PRIVATE_IP"
}

install_k3s_server() {
  log "Installing K3s server..."
  # Add TLS SANs for both the node's own IP and the private LB IP. Use $PRIVATE_IP (no braces)
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

  # Use upstream installer (works on OL9). Keep exact behaviour as original script.
  curl -sfL https://get.k3s.io | sh -

  log "Waiting for k3s kubeconfig file to appear: $K3S_KUBECONFIG"
  # Wait for kubeconfig file and for kube-apiserver to accept connections
  wait_secs=180
  waited=0
  while [ ! -s "$K3S_KUBECONFIG" ]; do
    sleep 2
    waited=$((waited+2))
    if [ "$waited" -ge "$wait_secs" ]; then
      log "❌ Timeout waiting for $K3S_KUBECONFIG to appear"
      ls -l /etc/rancher/k3s || true
      journalctl -u k3s --no-pager -n 200 || true
      exit 1
    fi
  done
  log "✅ kubeconfig present"

  # Use explicit kubeconfig for all kubectl calls
  export KUBECONFIG="$K3S_KUBECONFIG"

  log "Waiting for kube-apiserver to respond to kubectl version..."
  waited=0
  while true; do
    if $KUBECTL --kubeconfig="$K3S_KUBECONFIG" version --short >/dev/null 2>&1; then
      break
    fi
    sleep 2
    waited=$((waited+2))
    if [ "$waited" -ge "$wait_secs" ]; then
      log "❌ kube-apiserver did not respond in ${wait_secs}s"
      $KUBECTL --kubeconfig="$K3S_KUBECONFIG" get pods --all-namespaces || true
      journalctl -u k3s --no-pager -n 200 || true
      exit 1
    fi
  done
  log "✅ kube-apiserver responding"

  # Wait until this node becomes Ready
  log "Waiting for K3s server node to be Ready..."
  waited=0
  wait_node_secs=300
  while true; do
    if $KUBECTL --kubeconfig="$K3S_KUBECONFIG" get node "$(hostname)" --no-headers 2>/dev/null | awk '{print $2}' | grep -Eq '^Ready(,SchedulingDisabled)?$'; then
      break
    fi
    sleep 5
    waited=$((waited+5))
    if [ "$waited" -ge "$wait_node_secs" ]; then
      log "❌ Timeout waiting for node to be Ready"
      $KUBECTL --kubeconfig="$K3S_KUBECONFIG" get nodes -o wide || true
      exit 1
    fi
  done
  log "K3s server node is running and Ready."
}

wait_for_all_nodes() {
  log "Waiting for all $T_EXPECTED_NODE_COUNT nodes to join and become Ready..."
  timeout=900
  start_time=$(date +%s)
  while true; do
    ready_nodes=$($KUBECTL --kubeconfig="$K3S_KUBECONFIG" get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -Ec '^Ready(,SchedulingDisabled)?$' || true)
    if [ "$ready_nodes" -eq "$T_EXPECTED_NODE_COUNT" ]; then
      log "✅ All $T_EXPECTED_NODE_COUNT nodes are Ready. Proceeding."
      break
    fi
    elapsed_time=$(( $(date +%s) - start_time ))
    if [ "$elapsed_time" -gt "$timeout" ]; then
      log "❌ Timed out waiting for all nodes to become Ready."
      $KUBECTL --kubeconfig="$K3S_KUBECONFIG" get nodes || true
      exit 1
    fi
    log "(${elapsed_time}/${timeout} s) Currently ${ready_nodes}/${T_EXPECTED_NODE_COUNT} nodes are Ready. Waiting..."
    sleep 15
  done
}

install_helm() {
  if ! command -v helm &> /dev/null; then
    log "Installing Helm..."
    curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 /tmp/get_helm.sh
    /tmp/get_helm.sh
    rm -f /tmp/get_helm.sh
  else
    log "helm already installed"
  fi
  if [ -x "$HELM_BIN" ]; then
    log "Helm path: $HELM_BIN"
  else
    log "Helm not found at $HELM_BIN, using $(command -v helm || echo 'none')"
  fi
}

install_ingress_nginx() {
  log "Installing ingress-nginx via Helm (DaemonSet + NodePorts 30080/30443)..."

  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
  helm repo update || true

  $KUBECTL --kubeconfig="$K3S_KUBECONFIG" create namespace ingress-nginx --dry-run=client -o yaml | $KUBECTL --kubeconfig="$K3S_KUBECONFIG" apply -f - || true

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
    --kubeconfig "$K3S_KUBECONFIG"

  log "Waiting for ingress-nginx controller rollout..."
  $KUBECTL --kubeconfig="$K3S_KUBECONFIG" -n ingress-nginx rollout status ds/ingress-nginx-controller --timeout=10m || {
    log "Warning: ingress-nginx rollout did not finish within timeout. Showing pods:"
    $KUBECTL --kubeconfig="$K3S_KUBECONFIG" -n ingress-nginx get pods -o wide || true
  }
}

install_argo_cd() {
  log "Installing Argo CD..."
  $KUBECTL --kubeconfig="$K3S_KUBECONFIG" create namespace argocd --dry-run=client -o yaml | $KUBECTL --kubeconfig="$K3S_KUBECONFIG" apply -f - || true

  # Install ArgoCD
  $KUBECTL --kubeconfig="$K3S_KUBECONFIG" apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

  # Wait for core argocd resources to exist (give CRDs time to register)
  wait_for=300
  waited=0
  sleep_step=5
  while true; do
    if $KUBECTL --kubeconfig="$K3S_KUBECONFIG" -n argocd get deploy argocd-server >/dev/null 2>&1 && \
       $KUBECTL --kubeconfig="$K3S_KUBECONFIG" -n argocd get statefulset argocd-application-controller >/dev/null 2>&1; then
      break
    fi
    sleep $sleep_step
    waited=$((waited + sleep_step))
    if [ "$waited" -ge "$wait_for" ]; then
      log "❌ Timeout waiting for ArgoCD resources to be created"
      $KUBECTL --kubeconfig="$K3S_KUBECONFIG" -n argocd get all || true
      break
    fi
  done

  for d in argocd-server argocd-repo-server argocd-dex-server; do
    $KUBECTL --kubeconfig="$K3S_KUBECONFIG" -n argocd patch deployment "$d" --type='json' -p='[ 
      {"op":"add","path":"/spec/template/spec/tolerations","value":[
        {"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}
      ]} 
    ]' || true
  done

  $KUBECTL --kubeconfig="$K3S_KUBECONFIG" -n argocd patch statefulset argocd-application-controller --type='json' -p='[
    {"op":"add","path":"/spec/template/spec/tolerations","value":[
      {"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}
    ]}
  ]' || true

  log "Waiting for Argo CD components to be ready..."
  $KUBECTL --kubeconfig="$K3S_KUBECONFIG" -n argocd wait --for=condition=Available deployments --all --timeout=10m || {
    log "Warning: not all ArgoCD deployments reported Available within timeout"
    $KUBECTL --kubeconfig="$K3S_KUBECONFIG" -n argocd get pods -o wide || true
  }

  $KUBECTL --kubeconfig="$K3S_KUBECONFIG" -n argocd rollout status statefulset/argocd-application-controller --timeout=10m || {
    log "Warning: argocd-application-controller rollout status did not become ready within timeout"
  }
}

generate_secrets_and_credentials() {
  log "Generating credentials and Kubernetes secrets..."
  DB_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 || true)

  log "Waiting up to 2m for Argo CD initial admin secret..."
  waited=0
  while true; do
    if $KUBECTL --kubeconfig="$K3S_KUBECONFIG" -n argocd get secret argocd-initial-admin-secret >/dev/null 2>&1; then
      break
    fi
    sleep 5
    waited=$((waited+5))
    if [ "$waited" -ge 120 ]; then
      log "Argocd initial secret not available after 120s; proceeding (may be created later)."
      break
    fi
  done

  ARGO_PASSWORD=$($KUBECTL --kubeconfig="$K3S_KUBECONFIG" -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "changeme")

  cat << EOF > /root/credentials.txt
# --- Argo CD Admin Credentials ---
Username: admin
Password: $ARGO_PASSWORD

# --- PostgreSQL Database Credentials ---
Username: $T_DB_USER
Password: $DB_PASSWORD
EOF
  chmod 600 /root/credentials.txt
  log "Credentials saved to /root/credentials.txt"

  for ns in default development; do
    $KUBECTL --kubeconfig="$K3S_KUBECONFIG" create namespace "$ns" --dry-run=client -o yaml | $KUBECTL --kubeconfig="$K3S_KUBECONFIG" apply -f - || true
    $KUBECTL --kubeconfig="$K3S_KUBECONFIG" -n "$ns" create secret generic postgres-credentials \
      --from-literal=POSTGRES_USER="$T_DB_USER" \
      --from-literal=POSTGRES_PASSWORD="$DB_PASSWORD" \
      --dry-run=client -o yaml | $KUBECTL --kubeconfig="$K3S_KUBECONFIG" apply -f - || true
  done

  DB_URI_DEV="postgresql://$T_DB_USER:$DB_PASSWORD@${T_DB_SERVICE_NAME_DEV}-client.development.svc.cluster.local:5432/$T_DB_NAME_DEV"
  $KUBECTL --kubeconfig="$K3S_KUBECONFIG" -n development create secret generic backend-db-connection \
    --from-literal=DB_URI="$DB_URI_DEV" \
    --dry-run=client -o yaml | $KUBECTL --kubeconfig="$K3S_KUBECONFIG" apply -f - || true

  DB_URI_PROD="postgresql://$T_DB_USER:$DB_PASSWORD@${T_DB_SERVICE_NAME_PROD}-client.default.svc.cluster.local:5432/$T_DB_NAME_PROD"
  $KUBECTL --kubeconfig="$K3S_KUBECONFIG" -n default create secret generic backend-db-connection \
    --from-literal=DB_URI="$DB_URI_PROD" \
    --dry-run=client -o yaml | $KUBECTL --kubeconfig="$K3S_KUBECONFIG" apply -f - || true
}

bootstrap_argocd_apps() {
  log "Bootstrapping Argo CD with applications from manifest repo..."
  rm -rf /tmp/manifests || true

  if ! git clone "$T_MANIFESTS_REPO_URL" /tmp/manifests; then
    log "Warning: git clone of $T_MANIFESTS_REPO_URL failed. Skipping application bootstrap."
    return 0
  fi

  if [ -f /tmp/manifests/clusters/dev/apps/project.yaml ]; then
    $KUBECTL --kubeconfig="$K3S_KUBECONFIG" apply -f /tmp/manifests/clusters/dev/apps/project.yaml || true
  fi
  if [ -f /tmp/manifests/clusters/dev/apps/stack.yaml ]; then
    $KUBECTL --kubeconfig="$K3S_KUBECONFIG" apply -f /tmp/manifests/clusters/dev/apps/stack.yaml || true
  fi

  if [ -f /tmp/manifests/clusters/prod/apps/project.yaml ]; then
    $KUBECTL --kubeconfig="$K3S_KUBECONFIG" apply -f /tmp/manifests/clusters/prod/apps/project.yaml || true
  fi
  if [ -f /tmp/manifests/clusters/prod/apps/stack.yaml ]; then
    $KUBECTL --kubeconfig="$K3S_KUBECONFIG" apply -f /tmp/manifests/clusters/prod/apps/stack.yaml || true
  fi

  log "Argo CD applications applied (if manifests existed). Argo will now sync the cluster state."
}

main() {
  install_base_tools
  get_private_ip
  install_k3s_server
  wait_for_all_nodes
  install_helm
  install_ingress_nginx
  install_argo_cd
  generate_secrets_and_credentials
  bootstrap_argocd_apps
  log "Cloud-init user-data completed successfully."
}

main "$@"
