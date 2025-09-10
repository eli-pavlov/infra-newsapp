#!/bin/bash
# K3s SERVER install, tooling, secret generation, ingress-nginx install,
# and Argo CD bootstrapping.
# Converted for Oracle Linux 9 (dnf-based) — waits for kube-apiserver/kubeconfig
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

# Paths and tools
K3S_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
KUBECTL="/usr/local/bin/kubectl"
HELM_BIN="/usr/local/bin/helm"

log() { printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }

install_base_tools() {
  log "Installing base packages (dnf)..."
  dnf makecache --refresh -y || true
  dnf install -y curl jq git || true
}

# disable early
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
  PARAMS="--write-kubeconfig-mode 644 \
--node-ip $PRIVATE_IP \
--advertise-address $PRIVATE_IP \
--disable traefik \
--tls-san $PRIVATE_IP \
--tls-san ${T_PRIVATE_LB_IP} \
--kubelet-arg=register-with-taints=node-role.kubernetes.io/control-plane=true:NoSchedule"

  export INSTALL_K3S_EXEC="$PARAMS"
  export K3S_TOKEN="$T_K3S_TOKEN"
  export INSTALL_K3S_VERSION="$T_K3S_VERSION"

  curl -sfL https://get.k3s.io | sh -

  # Wait for kubeconfig file
  log "Waiting for kubeconfig $K3S_KUBECONFIG to be created (timeout 180s)..."
  waited=0
  while [ ! -s "$K3S_KUBECONFIG" ]; do
    sleep 2
    waited=$((waited+2))
    if [ "$waited" -ge 180 ]; then
      log "❌ Timeout waiting for kubeconfig to appear"
      ls -l /etc/rancher || true
      journalctl -u k3s --no-pager -n 200 || true
      exit 1
    fi
  done
  log "✅ kubeconfig present"

  # use explicit kubeconfig for all subsequent actions
  export KUBECONFIG="$K3S_KUBECONFIG"

  # Wait for API to answer kubectl version
  log "Waiting for kube-apiserver to accept connections (timeout 180s)..."
  waited=0
  while true; do
    if $KUBECTL --kubeconfig="$K3S_KUBECONFIG" version --short >/dev/null 2>&1; then
      break
    fi
    sleep 2
    waited=$((waited+2))
    if [ "$waited" -ge 180 ]; then
      log "❌ kube-apiserver did not respond in 180s"
      $KUBECTL --kubeconfig="$K3S_KUBECONFIG" get pods --all-namespaces || true
      journalctl -u k3s --no-pager -n 200 || true
      exit 1
    fi
  done
  log "✅ kube-apiserver responding"

  # Wait for local node to become Ready
  log "Waiting for local node to be Ready (timeout 300s)..."
  waited=0
  while true; do
    if $KUBECTL --kubeconfig="$K3S_KUBECONFIG" get node "$(hostname)" --no-headers 2>/dev/null | awk '{print $2}' | grep -Eq '^Ready(,SchedulingDisabled)?$'; then
      break
    fi
    sleep 5
    waited=$((waited+5))
    if [ "$waited" -ge 300 ]; then
      log "❌ Timeout waiting for node to be Ready"
      $KUBECTL --kubeconfig="$K3S_KUBECONFIG" get nodes -o wide || true
      exit 1
    fi
  done
  log "K3s server node is running and Ready."
}

wait_for_all_nodes() {
  log "Waiting for all ${T_EXPECTED_NODE_COUNT} nodes to join and become Ready (timeout 900s)..."
  timeout=900
  start_time=$(date +%s)
  while true; do
    ready_nodes=$($KUBECTL --kubeconfig="$K3S_KUBECONFIG" get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -Ec '^Ready(,SchedulingDisabled)?$' || true)
    if [ "$ready_nodes" -eq "$T_EXPECTED_NODE_COUNT" ]; then
      log "✅ All ${T_EXPECTED_NODE_COUNT} nodes are Ready."
      break
    fi
    elapsed=$(( $(date +%s) - start_time ))
    if [ "$elapsed" -gt "$timeout" ]; then
      log "❌ Timed out waiting for all nodes to be Ready"
      $KUBECTL --kubeconfig="$K3S_KUBECONFIG" get nodes || true
      exit 1
    fi
    log "(${elapsed}/${timeout}s) ${ready_nodes}/${T_EXPECTED_NODE_COUNT} Ready — sleeping 15s..."
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
  # Ensure helm picks up our kubeconfig
  export KUBECONFIG="$K3S_KUBECONFIG"
}

install_ingress_nginx() {
  log "Installing ingress-nginx via Helm (DaemonSet + NodePorts 30080/30443)..."
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
  helm repo update || true

  # Ensure namespace exists
  $KUBECTL create namespace ingress-nginx --dry-run=client -o yaml | $KUBECTL apply -f - || true

  # Install using explicit kubeconfig (KUBECONFIG exported)
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
    --kubeconfig "$K3S_KUBECONFIG" || {
      log "Warning: helm upgrade/install for ingress-nginx returned non-zero; continuing"
    }

  log "Waiting for ingress-nginx controller rollout (timeout 10m)..."
  $KUBECTL -n ingress-nginx rollout status ds/ingress-nginx-controller --kubeconfig="$K3S_KUBECONFIG" --timeout=10m || {
    log "Warning: ingress-nginx did not fully roll out within timeout; showing pods"
    $KUBECTL -n ingress-nginx get pods -o wide --kubeconfig="$K3S_KUBECONFIG" || true
  }
}

install_argo_cd() {
  log "Installing Argo CD..."
  $KUBECTL create namespace argocd --dry-run=client -o yaml | $KUBECTL apply -f - --kubeconfig="$K3S_KUBECONFIG" || true

  # Apply upstream install (includes CRDs)
  $KUBECTL apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --kubeconfig="$K3S_KUBECONFIG"

  # Wait for core resources to appear (give CRDs a short time)
  waited=0
  while true; do
    if $KUBECTL -n argocd get deploy argocd-server --kubeconfig="$K3S_KUBECONFIG" >/dev/null 2>&1 && \
       $KUBECTL -n argocd get statefulset argocd-application-controller --kubeconfig="$K3S_KUBECONFIG" >/dev/null 2>&1; then
      break
    fi
    sleep 5
    waited=$((waited+5))
    if [ "$waited" -ge 300 ]; then
      log "Warning: ArgoCD core resources did not appear in 300s"
      $KUBECTL -n argocd get all --kubeconfig="$K3S_KUBECONFIG" || true
      break
    fi
  done

  # Add tolerations for control plane if necessary
  for d in argocd-server argocd-repo-server argocd-dex-server; do
    $KUBECTL -n argocd patch deployment "$d" --type='json' -p='[
      {"op":"add","path":"/spec/template/spec/tolerations","value":[
        {"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}
      ]}
    ]' --kubeconfig="$K3S_KUBECONFIG" || true
  done

  $KUBECTL -n argocd patch statefulset argocd-application-controller --type='json' -p='[
    {"op":"add","path":"/spec/template/spec/tolerations","value":[
      {"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}
    ]}
  ]' --kubeconfig="$K3S_KUBECONFIG" || true

  log "Waiting for Argo CD deployments to be Available (timeout 10m)..."
  $KUBECTL -n argocd wait --for=condition=Available deployments --all --timeout=10m --kubeconfig="$K3S_KUBECONFIG" || {
    log "Warning: not all ArgoCD deployments became Available"
    $KUBECTL -n argocd get pods -o wide --kubeconfig="$K3S_KUBECONFIG" || true
  }
  $KUBECTL -n argocd rollout status statefulset/argocd-application-controller --timeout=10m --kubeconfig="$K3S_KUBECONFIG" || {
    log "Warning: argocd-application-controller rollout not completed within timeout"
  }
}

generate_secrets_and_credentials() {
  log "Generating credentials and Kubernetes secrets..."
  DB_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 || true)

  log "Waiting up to 120s for Argo CD initial admin secret..."
  waited=0
  while true; do
    if $KUBECTL -n argocd get secret argocd-initial-admin-secret --kubeconfig="$K3S_KUBECONFIG" >/dev/null 2>&1; then
      break
    fi
    sleep 5
    waited=$((waited+5))
    if [ "$waited" -ge 120 ]; then
      log "Argocd initial secret not available after 120s; will proceed and use fallback password"
      break
    fi
  done

  ARGO_PASSWORD=$($KUBECTL -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" --kubeconfig="$K3S_KUBECONFIG" 2>/dev/null | base64 -d || echo "changeme")

  cat << EOF > /root/credentials.txt
# --- Argo CD Admin Credentials ---
Username: admin
Password: $${ARGO_PASSWORD}

# --- PostgreSQL Database Credentials ---
Username: ${T_DB_USER}
Password: $${DB_PASSWORD}
EOF
  chmod 600 /root/credentials.txt
  log "Credentials saved to /root/credentials.txt"

  for ns in default development; do
    $KUBECTL create namespace "$ns" --dry-run=client -o yaml | $KUBECTL apply -f - --kubeconfig="$K3S_KUBECONFIG" || true
    $KUBECTL -n "$ns" create secret generic postgres-credentials \
      --from-literal=POSTGRES_USER="${T_DB_USER}" \
      --from-literal=POSTGRES_PASSWORD="$${DB_PASSWORD}" \
      --dry-run=client -o yaml | $KUBECTL apply -f - --kubeconfig="$K3S_KUBECONFIG" || true
  done

  DB_URI_DEV="postgresql://${T_DB_USER}:$${DB_PASSWORD}@${T_DB_SERVICE_NAME_DEV}-client.development.svc.cluster.local:5432/${T_DB_NAME_DEV}"
  $KUBECTL -n development create secret generic backend-db-connection \
    --from-literal=DB_URI="$${DB_URI_DEV}" \
    --dry-run=client -o yaml | $KUBECTL apply -f - --kubeconfig="$K3S_KUBECONFIG" || true

  DB_URI_PROD="postgresql://${T_DB_USER}:$${DB_PASSWORD}@${T_DB_SERVICE_NAME_PROD}-client.default.svc.cluster.local:5432/${T_DB_NAME_PROD}"
  $KUBECTL -n default create secret generic backend-db-connection \
    --from-literal=DB_URI="$${DB_URI_PROD}" \
    --dry-run=client -o yaml | $KUBECTL apply -f - --kubeconfig="$K3S_KUBECONFIG" || true
}

bootstrap_argocd_apps() {
  log "Bootstrapping Argo CD with applications from manifest repo..."
  rm -rf /tmp/manifests || true
  if ! git clone "${T_MANIFESTS_REPO_URL}" /tmp/manifests; then
    log "Warning: git clone failed; skipping manifest bootstrap"
    return 0
  fi

  if [ -f /tmp/manifests/clusters/dev/apps/project.yaml ]; then
    $KUBECTL apply -f /tmp/manifests/clusters/dev/apps/project.yaml --kubeconfig="$K3S_KUBECONFIG" || true
  fi
  if [ -f /tmp/manifests/clusters/dev/apps/stack.yaml ]; then
    $KUBECTL apply -f /tmp/manifests/clusters/dev/apps/stack.yaml --kubeconfig="$K3S_KUBECONFIG" || true
  fi
  if [ -f /tmp/manifests/clusters/prod/apps/project.yaml ]; then
    $KUBECTL apply -f /tmp/manifests/clusters/prod/apps/project.yaml --kubeconfig="$K3S_KUBECONFIG" || true
  fi
  if [ -f /tmp/manifests/clusters/prod/apps/stack.yaml ]; then
    $KUBECTL apply -f /tmp/manifests/clusters/prod/apps/stack.yaml --kubeconfig="$K3S_KUBECONFIG" || true
  fi

  log "Argo CD applications applied (if manifests existed)."
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
