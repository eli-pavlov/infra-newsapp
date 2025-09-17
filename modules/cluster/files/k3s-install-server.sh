#!/bin/bash
# K3s SERVER install, tooling, secret generation, ingress-nginx install,
# and Argo CD bootstrapping.
set -euo pipefail
# Simpler robust logging (avoid SIGPIPE issues of tee|logger chain)
exec > /var/log/cloud-init-output.log 2>&1
# Report failing command with line number
trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR

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
T_CLOUDFLARE_API_TOKEN="${T_CLOUDFLARE_API_TOKEN}"

DB_PORT="5432"
DB_HOST_DEV="${T_DB_SERVICE_NAME_DEV}-client.development.svc.cluster.local"
DB_HOST_PROD="${T_DB_SERVICE_NAME_PROD}-client.default.svc.cluster.local"

set -x

install_base_tools() {
  echo "Installing base packages (dnf)..."
  dnf makecache --refresh -y || true
  dnf update -y
  dnf install -y curl jq git || true
}

systemctl disable firewalld --now || true

get_private_ip() {
  echo "Fetching instance private IP from metadata (OCI metadata endpoint)..."
  PRIVATE_IP=$(curl -s -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/vnics/ | jq -r '.[0].privateIp')
  if [ -z "$PRIVATE_IP" ] || [ "$PRIVATE_IP" = "null" ]; then
    echo "❌ Failed to fetch private IP."
    exit 1
  fi
  echo "✅ Instance private IP is $PRIVATE_IP"
}

install_k3s_server() {
  echo "Installing K3s server..."
  local PARAMS="--write-kubeconfig-mode 644 \
    --node-ip $PRIVATE_IP \
    --advertise-address $PRIVATE_IP \
    --disable traefik \
    --tls-san $PRIVATE_IP \
    --tls-san $T_PRIVATE_LB_IP \
    --kubelet-arg=register-with-taints=node-role.kubernetes.io/control-plane=true:NoSchedule"

  export INSTALL_K3S_EXEC="$PARAMS"
  export K3S_TOKEN="$T_K3S_TOKEN"
  export INSTALL_K3S_VERSION="$T_K3S_VERSION"

  curl -sfL https://get.k3s.io | sh -
  echo "Waiting for K3s server node to be Ready..."
  while ! /usr/local/bin/kubectl get node "$(hostname)" 2>/dev/null | grep -q 'Ready'; do sleep 5; done
  echo "K3s server node is running."
}

wait_for_kubeconfig_and_api() {
  echo "Waiting for kubeconfig and API readiness..."
  local timeout=120
  local start_time
  start_time=$(date +%s)
  while true; do
    if [ ! -f /etc/rancher/k3s/k3s.yaml ]; then
      echo "Waiting for kubeconfig file..."
      sleep 5
      continue
    fi
    if /usr/local/bin/kubectl get nodes 2>/dev/null | grep -q 'Ready'; then
      # Light check for core system pods
      if /usr/local/bin/kubectl get pods -n kube-system 2>/dev/null | grep -qE '(etcd|coredns|kube-proxy|kube-scheduler|kube-controller)'; then
        echo "✅ Kubeconfig + API are ready."
        break
      fi
    fi
    local elapsed_time=$(( $(date +%s) - start_time ))
    if [ "$elapsed_time" -gt "$timeout" ]; then
      echo "❌ Timed out waiting for kubeconfig/API"
      /usr/local/bin/kubectl cluster-info || true
      exit 1
    fi
    sleep 5
  done
}

wait_for_all_nodes() {
  echo "Waiting for all $T_EXPECTED_NODE_COUNT nodes to join and become Ready..."
  local timeout=900
  local start_time; start_time=$(date +%s)
  while true; do
    local ready_nodes
    ready_nodes=$(/usr/local/bin/kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -Ec '^Ready(,SchedulingDisabled)?$' || true)
    if [ "$ready_nodes" -eq "$T_EXPECTED_NODE_COUNT" ]; then
      echo "✅ All $T_EXPECTED_NODE_COUNT nodes are Ready."
      break
    fi
    local elapsed_time=$(( $(date +%s) - start_time ))
    if [ "$elapsed_time" -gt "$timeout" ]; then
      echo "❌ Timed out waiting for nodes to become Ready."
      /usr/local/bin/kubectl get nodes || true
      exit 1
    fi
    echo "($elapsed_time/$timeout s) $ready_nodes/$T_EXPECTED_NODE_COUNT ready; sleeping 15s..."
    sleep 15
  done
}

install_helm() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  export PATH=$PATH:/usr/local/bin
  if ! command -v helm &> /dev/null; then
    echo "Installing Helm..."
    curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 /tmp/get_helm.sh
    /tmp/get_helm.sh
    rm -f /tmp/get_helm.sh
  fi
}


bootstrap_argo_cd_instance() {
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    echo "Bootstrapping Argo CD instance directly via Helm..."

    # 1. Create the Argo CD namespace
    /usr/local/bin/kubectl create namespace argocd --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f -
    /usr/local/bin/kubectl create namespace development --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f -

    # 2. Add the argo-helm repository
    /usr/local/bin/helm repo add argo https://argoproj.github.io/argo-helm
    /usr/local/bin/helm repo update

    # 3. Install Argo CD using Helm with overrides
    /usr/local/bin/helm install argocd argo/argo-cd \
        --version 8.3.7 \
        --namespace argocd \
        \
        `# Ingress Configuration` \
        --set server.ingress.enabled=true \
        --set server.ingress.ingressClassName=nginx \
        --set server.ingress.hostname="argocd.weblightenment.com" \
        --set server.ingress.annotations."nginx\.ingress\.kubernetes\.io/backend-protocol"=HTTP \
        --set server.ingress.annotations."nginx\.ingress\.kubernetes\.io/force-ssl-redirect"=true \
        --set server.ingress.tls[0].secretName=argocd-tls \
        --set server.ingress.tls[0].hosts[0]="argocd.weblightenment.com" \
        \
        `# Server Configuration for TLS Termination` \
        --set server.extraArgs='{--insecure}' \
        \
        `# Tolerations for all necessary components` \
        --set server.tolerations[0].key="node-role.kubernetes.io/control-plane" \
        --set server.tolerations[0].operator="Exists" \
        --set server.tolerations[0].effect="NoSchedule" \
        --set controller.tolerations[0].key="node-role.kubernetes.io/control-plane" \
        --set controller.tolerations[0].operator="Exists" \
        --set controller.tolerations[0].effect="NoSchedule" \
        --set repoServer.tolerations[0].key="node-role.kubernetes.io/control-plane" \
        --set repoServer.tolerations[0].operator="Exists" \
        --set repoServer.tolerations[0].effect="NoSchedule" \
        --set dex.tolerations[0].key="node-role.kubernetes.io/control-plane" \
        --set dex.tolerations[0].operator="Exists" \
        --set dex.tolerations[0].effect="NoSchedule" \
        --set redis.tolerations[0].key="node-role.kubernetes.io/control-plane" \
        --set redis.tolerations[0].operator="Exists" \
        --set redis.tolerations[0].effect="NoSchedule"

    # 4. Wait for Argo CD to be ready
    echo "Waiting for Argo CD to become available..."
    /usr/local/bin/kubectl wait --for=condition=Available -n argocd deployment/argocd-server --timeout=5m
}

generate_secrets_and_credentials() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  sleep 30
  echo "Generating credentials and Kubernetes secrets..."
  ARGO_PASSWORD=$(/usr/local/bin/kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null || echo "" )
  if [ -n "$ARGO_PASSWORD" ]; then
    ARGO_PASSWORD=$(echo "$ARGO_PASSWORD" | base64 -d)
  else
    ARGO_PASSWORD="(unknown)"
  fi

  # generate DB_PASSWORD
  DB_PASSWORD=$(python3 - <<'PY'
import secrets,string
print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(32)))
PY
)

  # Write credentials file for operator convenience
  cat << EOF > /root/credentials.txt
  # --- Argo CD Admin Credentials ---
Username: admin
Password: $${ARGO_PASSWORD}
# --- PostgreSQL Database Credentials ---
Username: ${T_DB_USER}
Password: ${DB_PASSWORD}
EOF
  chmod 600 /root/credentials.txt
  echo "Credentials saved to /root/credentials.txt"

  #
  # Create postgres-credentials (used by the postgres chart)
  #
  for ns in default development; do
    /usr/local/bin/kubectl create namespace "$ns" --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f - || true
    /usr/local/bin/kubectl -n "$ns" create secret generic postgres-credentials \
      --from-literal=POSTGRES_USER="${T_DB_USER}" \
      --from-literal=POSTGRES_PASSWORD="${DB_PASSWORD}" \
      --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f - || true
  done

  #
  # Create backend-db-connection secret for backend Pods
  # Provide DB_URI (required by the app) + individual keys (safer for templates/initContainers)
  #
  # Build URIs (dev and prod)
  DB_URI_DEV="postgresql://${T_DB_USER}:${DB_PASSWORD}@${T_DB_SERVICE_NAME_DEV}-client.development.svc.cluster.local:${DB_PORT}/${T_DB_NAME_DEV}"
  DB_URI_PROD="postgresql://${T_DB_USER}:${DB_PASSWORD}@${T_DB_SERVICE_NAME_PROD}-client.default.svc.cluster.local:${DB_PORT}/${T_DB_NAME_PROD}"

  # Dev secret (development namespace)
  /usr/local/bin/kubectl -n development create secret generic backend-db-connection \
    --from-literal=DB_URI="${DB_URI_DEV}" \
    --from-literal=DB_USER="${T_DB_USER}" \
    --from-literal=DB_NAME="${T_DB_NAME_DEV}" \
    --from-literal=POSTGRES_PASSWORD="${DB_PASSWORD}" \
    --from-literal=DB_HOST="${T_DB_SERVICE_NAME_DEV}-client.development.svc.cluster.local" \
    --from-literal=DB_PORT="${DB_PORT}" \
    --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f - || true

  # Prod secret (default namespace)
  /usr/local/bin/kubectl -n default create secret generic backend-db-connection \
    --from-literal=DB_URI="${DB_URI_PROD}" \
    --from-literal=DB_USER="${T_DB_USER}" \
    --from-literal=DB_NAME="${T_DB_NAME_PROD}" \
    --from-literal=POSTGRES_PASSWORD="${DB_PASSWORD}" \
    --from-literal=DB_HOST="${T_DB_SERVICE_NAME_PROD}-client.default.svc.cluster.local" \
    --from-literal=DB_PORT="${DB_PORT}" \
    --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f - || true

  #
  # cert-manager cloudflare token (optional)
  #
  if [ -n "$${T_CLOUDFLARE_API_TOKEN:-}" ]; then
    echo "Creating cert-manager Cloudflare API token secret..."
    /usr/local/bin/kubectl create namespace cert-manager --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f - || true
    /usr/local/bin/kubectl -n cert-manager create secret generic cloudflare-api-token-secret \
      --from-literal=api-token="${T_CLOUDFLARE_API_TOKEN}" --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f - || true
    echo "cloudflare-api-token-secret created/updated in cert-manager."
  else
    echo "T_CLOUDFLARE_API_TOKEN not set — skipping cert-manager Cloudflare secret creation."
  fi
}


bootstrap_argocd_apps() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo "Bootstrapping Argo CD Applications from manifests repo: ${T_MANIFESTS_REPO_URL}"
  # Ensure repo is cloned locally.
  TMP_MANIFESTS_DIR="/tmp/newsapp-manifests"
  if [ -d "$TMP_MANIFESTS_DIR/.git" ]; then
    echo "Local clone exists; attempting git -C pull..."
    git -C "$TMP_MANIFESTS_DIR" pull --ff-only || true
  else
    # clone, but do not fail cluster bootstrap if clone fails (let ArgoCD still be able to fetch via registered repo)
    if ! git clone --depth 1 "${T_MANIFESTS_REPO_URL}" "$TMP_MANIFESTS_DIR"; then
      echo "Warning: git clone failed for ${T_MANIFESTS_REPO_URL}; continuing and attempting to apply remote raw manifests where possible."
    fi
  fi
  # Apply Project + stack Application CRs (dev & prod)
  set +e
  # Apply the single root application that manages everything else
   if [ -f "$TMP_MANIFESTS_DIR/newsapp-master-app.yaml" ]; then
    /usr/local/bin/kubectl apply -f "$TMP_MANIFESTS_DIR/newsapp-master-app.yaml"  
   else
     echo "❌ newsapp-master-app.yaml not found in repository. Cannot bootstrap Argo CD."
     exit 1
   fi
  set -e
  echo "Waiting up to 5m for applications to become Healthy..."
  /usr/local/bin/kubectl -n argocd wait --for=condition=Healthy application/newsapp-master-app --timeout=5m || true
  echo "Argo CD Application CRs applied (from local clone or raw URLs)."
}


main() {
  install_base_tools
  get_private_ip
  install_k3s_server
  wait_for_kubeconfig_and_api
  wait_for_all_nodes
  install_helm
  bootstrap_argo_cd_instance
  generate_secrets_and_credentials
  bootstrap_argocd_apps
}

main "$@"