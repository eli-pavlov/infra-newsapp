#!/bin/bash
# Heavy bootstrap script for K3s server, executed by systemd oneshot.
# This script is shipped raw (base64) by Terraform and created on the instance
# by the cloud-init wrapper. It MUST NOT be processed by Terraform templatefile().
set -euo pipefail

# Log to file (systemd will also capture journal)
exec > /var/log/bootstrap-newsapp.log 2>&1
trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR

# Source runtime env written by cloudinit-wrapper.tpl
if [ -f /etc/bootstrap-env ]; then
  # shellcheck disable=SC1091
  source /etc/bootstrap-env
else
  echo "/etc/bootstrap-env not found; aborting"
  exit 1
fi

# Make kubectl references explicit later
KUBECTL=/usr/local/bin/kubectl

install_base_tools() {
  echo "Installing base packages (dnf)..."
  dnf makecache --refresh -y || true
  dnf update -y
  dnf install -y curl jq git || true
}

systemctl disable firewalld --now || true

get_private_ip() {
  echo "Fetching instance private IP from metadata (OCI metadata endpoint)..."
  PRIVATE_IP=$(curl -s -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/vnics/ | jq -r '.[0].privateIp' 2>/dev/null || true)
  if [ -z "${PRIVATE_IP:-}" ] || [ "$PRIVATE_IP" = "null" ]; then
    echo "❌ Failed to fetch private IP."
    exit 1
  fi
  echo "✅ Instance private IP is $PRIVATE_IP"
}

install_k3s_server() {
  echo "Installing K3s server..."

  # Add TLS SANs for both the node's own IP and the private LB IP
  PARAMS="--write-kubeconfig-mode 644 \
    --node-ip ${PRIVATE_IP} \
    --advertise-address ${PRIVATE_IP} \
    --disable traefik \
    --tls-san ${PRIVATE_IP} \
    --tls-san ${T_PRIVATE_LB_IP} \
    --kubelet-arg=register-with-taints=node-role.kubernetes.io/control-plane=true:NoSchedule"

  export INSTALL_K3S_EXEC="${PARAMS}"
  export K3S_TOKEN="${T_K3S_TOKEN}"
  export INSTALL_K3S_VERSION="${T_K3S_VERSION}"

  # Use upstream installer (works on OL9)
  echo "Running k3s installer with INSTALL_K3S_EXEC=${INSTALL_K3S_EXEC}"
  curl -sfL https://get.k3s.io | sh -

  echo "Waiting for K3s server node to be Ready..."
  # Wait until kubectl from k3s observes this node Ready
  # Note: kubeconfig created by installer at /etc/rancher/k3s/k3s.yaml
  while true; do
    if [ -f /etc/rancher/k3s/k3s.yaml ]; then
      break
    fi
    echo "Waiting for /etc/rancher/k3s/k3s.yaml..."
    sleep 3
  done

  # wait until kubectl sees this node Ready
  until ${KUBECTL} get node "$(hostname)" 2>/dev/null | grep -q 'Ready'; do
    echo "Waiting for node $(hostname) to show Ready..."
    sleep 5
  done

  echo "K3s server node is running."
}

wait_for_kubeconfig_and_api() {
  KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
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

    if ${KUBECTL} get nodes 2>/dev/null | grep -q 'Ready'; then
      # Basic presence check for core kube-system pods
      if ${KUBECTL} get pods -n kube-system 2>/dev/null | grep -qE '(etcd|coredns|kube-proxy|kube-scheduler|kube-controller)'; then
        echo "✅ Kubeconfig and API are ready."
        break
      fi
    fi

    local elapsed_time=$(( $(date +%s) - start_time ))
    if [ "$elapsed_time" -gt "$timeout" ]; then
      echo "❌ Timed out waiting for kubeconfig and API readiness."
      ${KUBECTL} cluster-info || true
      exit 1
    fi

    echo "($elapsed_time/$timeout s) Waiting for kubeconfig and API readiness..."
    sleep 5
  done
}

wait_for_all_nodes() {
  KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo "Waiting for all ${T_EXPECTED_NODE_COUNT} nodes to join and become Ready..."
  local timeout=900
  local start_time; start_time=$(date +%s)
  while true; do
    local ready_nodes
    ready_nodes=$(${KUBECTL} get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -Ec '^Ready(,SchedulingDisabled)?$' || true)
    if [ "$ready_nodes" -eq "$T_EXPECTED_NODE_COUNT" ]; then
      echo "✅ All ${T_EXPECTED_NODE_COUNT} nodes are Ready."
      break
    fi
    local elapsed_time=$(( $(date +%s) - start_time ))
    if [ "$elapsed_time" -gt "$timeout" ]; then
      echo "❌ Timed out waiting for all nodes to become Ready."
      ${KUBECTL} get nodes || true
      exit 1
    fi
    echo "($elapsed_time/$timeout s) Currently $ready_nodes/${T_EXPECTED_NODE_COUNT} nodes are Ready. Waiting..."
    sleep 15
  done
}

install_helm() {
  KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  if ! command -v helm &> /dev/null; then
    echo "Installing Helm..."
    curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 /tmp/get_helm.sh
    /tmp/get_helm.sh
    rm -f /tmp/get_helm.sh
  else
    echo "Helm already installed."
  fi
}

install_ingress_nginx() {
  KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo "Installing ingress-nginx via Helm..."
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
  helm repo update || true
  ${KUBECTL} create namespace ingress-nginx || true

  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --set controller.kind=DaemonSet \
    --set controller.service.type=NodePort \
    --set controller.service.nodePorts.http=30080 \
    --set controller.service.nodePorts.https=30443 \
    --set controller.service.externalTrafficPolicy=Local \
    --set controller.nodeSelector.role=application \
    --set controller.ingressClassResource.name=nginx \
    --set controller.ingressClassByName=true || true

  echo "Waiting for ingress-nginx controller rollout..."
  ${KUBECTL} -n ingress-nginx rollout status ds/ingress-nginx-controller --timeout=5m || true
}

install_argo_cd() {
  KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo "Installing Argo CD..."
  ${KUBECTL} create namespace argocd || true
  ${KUBECTL} apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml || true

  for d in argocd-server argocd-repo-server argocd-dex-server; do
    ${KUBECTL} -n argocd patch deployment "$d" --type='json' -p='[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}]' || true
  done

  ${KUBECTL} -n argocd patch statefulset argocd-application-controller --type='json' -p='[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}]' || true

  ${KUBECTL} -n argocd wait --for=condition=Available deployments --all --timeout=5m || true
  ${KUBECTL} -n argocd rollout status statefulset/argocd-application-controller --timeout=5m || true
}

# Per your request: do not block indefinitely waiting for the argocd-initial-admin-secret.
# Sleep 30s to give Argo CD a chance to create it; if missing, write credentials file with placeholder.
generate_secrets_and_credentials() {
  KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo "Sleeping 30 seconds to allow Argo CD to initialize (no blocking wait for secret)..."
  sleep 30

  echo "Generating credentials and Kubernetes secrets..."
  DB_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)

  # Try to fetch Argo CD initial admin password; if missing, use placeholder "(not-found)"
  ARGO_B64=$(${KUBECTL} -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null || true)
  if [ -n "${ARGO_B64:-}" ]; then
    # Avoid pipes that can cause SIGPIPE; use here-string
    ARGO_PASSWORD=$(base64 -d <<< "${ARGO_B64}" 2>/dev/null || echo "(decode-failed)")
  else
    ARGO_PASSWORD="(not-found)"
  fi

  # Persist credentials to a root-owned file
  cat > /root/credentials.txt <<EOF
# --- Argo CD Admin Credentials ---
Username: admin
Password: ${ARGO_PASSWORD}

# --- PostgreSQL Database Credentials ---
Username: ${T_DB_USER}
Password: ${DB_PASSWORD}
EOF

  chmod 600 /root/credentials.txt
  echo "Credentials saved to /root/credentials.txt"

  # Create namespaces and apply secrets
  for ns in default development; do
    ${KUBECTL} create namespace "$ns" --dry-run=client -o yaml | ${KUBECTL} apply -f - || true
    ${KUBECTL} -n "$ns" create secret generic postgres-credentials \
      --from-literal=POSTGRES_USER="${T_DB_USER}" \
      --from-literal=POSTGRES_PASSWORD="${DB_PASSWORD}" \
      --dry-run=client -o yaml | ${KUBECTL} apply -f - || true
  done

  # DB connection secrets
  DB_URI_DEV="postgresql://${T_DB_USER}:${DB_PASSWORD}@${T_DB_SERVICE_NAME_DEV}-client.development.svc.cluster.local:5432/${T_DB_NAME_DEV}"
  ${KUBECTL} -n development create secret generic backend-db-connection --from-literal=DB_URI="${DB_URI_DEV}" --dry-run=client -o yaml | ${KUBECTL} apply -f - || true

  DB_URI_PROD="postgresql://${T_DB_USER}:${DB_PASSWORD}@${T_DB_SERVICE_NAME_PROD}-client.default.svc.cluster.local:5432/${T_DB_NAME_PROD}"
  ${KUBECTL} -n default create secret generic backend-db-connection --from-literal=DB_URI="${DB_URI_PROD}" --dry-run=client -o yaml | ${KUBECTL} apply -f - || true
}

bootstrap_argocd_apps() {
  KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  if [ -n "${T_MANIFESTS_REPO_URL:-}" ]; then
    echo "Bootstrapping Argo CD with applications from manifest repo: ${T_MANIFESTS_REPO_URL}"
    rm -rf /tmp/manifests || true
    git clone "${T_MANIFESTS_REPO_URL}" /tmp/manifests || true

    [ -f /tmp/manifests/clusters/dev/apps/project.yaml ] && ${KUBECTL} apply -f /tmp/manifests/clusters/dev/apps/project.yaml || true
    [ -f /tmp/manifests/clusters/dev/apps/stack.yaml ]   && ${KUBECTL} apply -f /tmp/manifests/clusters/dev/apps/stack.yaml   || true
    [ -f /tmp/manifests/clusters/prod/apps/project.yaml ] && ${KUBECTL} apply -f /tmp/manifests/clusters/prod/apps/project.yaml || true
    [ -f /tmp/manifests/clusters/prod/apps/stack.yaml ]   && ${KUBECTL} apply -f /tmp/manifests/clusters/prod/apps/stack.yaml   || true
  else
    echo "T_MANIFESTS_REPO_URL empty; skipping Argo CD app bootstrap."
  fi
}

main() {
  install_base_tools
  get_private_ip
  install_k3s_server
  wait_for_kubeconfig_and_api
  wait_for_all_nodes
  install_helm
  install_ingress_nginx
  install_argo_cd
  generate_secrets_and_credentials
  bootstrap_argocd_apps
}

main "$@"
