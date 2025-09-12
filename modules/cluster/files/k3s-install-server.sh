#!/bin/bash
# Heavy bootstrap script for K3s server. Intended to be executed by cloud-init
# (previously run as a systemd oneshot in your wrapper). This version avoids
# fragile pipelines and uses temporary files for intermediate data.
set -euo pipefail

# Log to file (systemd will also capture journal)
exec > /var/log/bootstrap-newsapp.log 2>&1
trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR

# Create a private temp dir and ensure cleanup
TMPDIR=$(mktemp -d -t bootstrap.XXXXXX)
cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

# Source runtime env written by cloudinit-wrapper.tpl (or produced directly by cloud-init)
if [ -f /etc/bootstrap-env ]; then
  # shellcheck disable=SC1091
  source /etc/bootstrap-env
else
  echo "/etc/bootstrap-env not found; aborting"
  exit 1
fi

KUBECTL=/usr/local/bin/kubectl

install_base_tools() {
  echo "Installing base packages (dnf)..."
  dnf makecache --refresh -y || true
  dnf update -y
  # jq and curl are used; git is used later for manifests
  dnf install -y curl jq git openssl || true
}

# Best-effort: disable firewalld if present
if command -v systemctl >/dev/null 2>&1; then
  systemctl disable firewalld --now || true
fi

get_private_ip() {
  echo "Fetching instance private IP from metadata (OCI metadata endpoint)..."
  local vnics_json="$TMPDIR/vnics.json"
  # Save to file instead of piping into jq
  if ! curl -s -H "Authorization: Bearer Oracle" -L "http://169.254.169.254/opc/v2/vnics/" -o "$vnics_json"; then
    echo "❌ Failed to fetch VNICS from metadata"
    exit 1
  fi

  PRIVATE_IP=$(jq -r '.[0].privateIp' "$vnics_json" 2>/dev/null || true)
  if [ -z "${PRIVATE_IP:-}" ] || [ "$PRIVATE_IP" = "null" ]; then
    echo "❌ Failed to parse private IP from metadata."
    cat "$vnics_json"
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

  # safer than `curl | sh` — download the installer and run it explicitly
  local k3s_installer="$TMPDIR/get-k3s.sh"
  if ! curl -sfL -o "$k3s_installer" "https://get.k3s.io"; then
    echo "❌ Failed to download k3s installer."
    exit 1
  fi
  chmod 700 "$k3s_installer"
  echo "Running k3s installer with INSTALL_K3S_EXEC=${INSTALL_K3S_EXEC}"
  sh "$k3s_installer"

  echo "Waiting for K3s server node to be Ready..."
  # Wait until kubeconfig exists
  while [ ! -f /etc/rancher/k3s/k3s.yaml ]; do
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
  export KUBECONFIG
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
  export KUBECONFIG
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
  export KUBECONFIG
  if ! command -v helm &> /dev/null; then
    echo "Installing Helm..."
    curl -fsSL -o "$TMPDIR/get_helm.sh" https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 "$TMPDIR/get_helm.sh"
    "$TMPDIR/get_helm.sh"
    rm -f "$TMPDIR/get_helm.sh"
  else
    echo "Helm already installed."
  fi
}

install_ingress_nginx() {
  KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  export KUBECONFIG
  echo "Installing ingress-nginx via Helm..."
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
  helm repo update || true
  ${KUBECTL} create namespace ingress-nginx --dry-run=client -o yaml > "$TMPDIR/ingress-ns.yaml" || true
  ${KUBECTL} apply -f "$TMPDIR/ingress-ns.yaml" || true

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
  export KUBECONFIG
  echo "Installing Argo CD..."
  ${KUBECTL} create namespace argocd --dry-run=client -o yaml > "$TMPDIR/argocd-ns.yaml" || true
  ${KUBECTL} apply -f "$TMPDIR/argocd-ns.yaml" || true

  ${KUBECTL} apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml || true

  for d in argocd-server argocd-repo-server argocd-dex-server; do
    ${KUBECTL} -n argocd patch deployment "$d" --type='json' \
      -p='[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}]' || true
  done

  ${KUBECTL} -n argocd patch statefulset argocd-application-controller --type='json' \
    -p='[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}]' || true

  ${KUBECTL} -n argocd wait --for=condition=Available deployments --all --timeout=5m || true
  ${KUBECTL} -n argocd rollout status statefulset/argocd-application-controller --timeout=5m || true
}

ensure_argocd_ingress_and_server() {
  set -euo pipefail
  KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  export KUBECONFIG
  # Idempotent Ingress creation via apply from heredoc (not a pipeline)
  kubectl -n argocd apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server-ingress
  namespace: argocd
  annotations:
    kubernetes.io/ingress.class: "nginx"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  tls:
    - hosts:
        - argocd.weblightenment.com
      secretName: argocd-tls
  rules:
    - host: argocd.weblightenment.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
EOF

  kubectl -n argocd annotate ingress argocd-server-ingress \
    nginx.ingress.kubernetes.io/backend-protocol='HTTPS' --overwrite >/dev/null || true

  kubectl -n argocd patch ingress argocd-server-ingress --type='merge' -p '{
    "spec": {
      "tls": [
        {
          "hosts": ["argocd.weblightenment.com"],
          "secretName": "argocd-tls"
        }
      ]
    }
  }' >/dev/null || true

  # Create TLS secret from provided PEMs if CERT_FILE/KEY_FILE set; avoid piping by using a temp file
  if [[ -n "${CERT_FILE:-}" && -n "${KEY_FILE:-}" ]]; then
    "${KUBECTL}" -n argocd create secret tls argocd-tls \
      --cert="${CERT_FILE}" --key="${KEY_FILE}" --dry-run=client -o yaml > "$TMPDIR/argocd-tls.yaml" || true
    "${KUBECTL}" apply -f "$TMPDIR/argocd-tls.yaml" || true
    echo "Created/updated argocd-tls secret from provided CERT_FILE/KEY_FILE."
  else
    echo "CERT_FILE/KEY_FILE not set — not creating TLS secret."
  fi

  kubectl -n argocd patch configmap argocd-cm --type=merge -p '{"data":{"url":"https://argocd.weblightenment.com"}}' || true
  kubectl -n argocd rollout restart deployment argocd-server || true

  echo "Ingress/annotations applied and argocd-server restarted."
}

# Do not block forever waiting for ArgoCD; generate secrets and write credentials file
generate_secrets_and_credentials() {
  KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  export KUBECONFIG
  echo "Sleeping 30 seconds to allow Argo CD to initialize (no blocking wait for secret)..."
  sleep 30

  echo "Generating credentials and Kubernetes secrets..."
  DB_PASSWORD=$(python3 -c 'import secrets, string; print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(32)))')
  # Try to fetch Argo CD initial admin password; if missing, use placeholder "(not-found)"
  ARGO_B64=$(${KUBECTL} -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null || true)
  if [ -n "${ARGO_B64:-}" ]; then
    # decode safely (here-string is fine)
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

  # Create namespaces and apply secrets using temporary YAML files (avoid pipes)
  for ns in default development; do
    ${KUBECTL} create namespace "$ns" --dry-run=client -o yaml > "$TMPDIR/${ns}-ns.yaml" || true
    ${KUBECTL} apply -f "$TMPDIR/${ns}-ns.yaml" || true

    ${KUBECTL} -n "$ns" create secret generic postgres-credentials \
      --from-literal=POSTGRES_USER="${T_DB_USER}" \
      --from-literal=POSTGRES_PASSWORD="${DB_PASSWORD}" \
      --dry-run=client -o yaml > "$TMPDIR/${ns}-postgres-creds.yaml" || true
    ${KUBECTL} apply -f "$TMPDIR/${ns}-postgres-creds.yaml" || true
  done

  # DB connection secrets (write to files then apply)
  DB_URI_DEV="postgresql://${T_DB_USER}:${DB_PASSWORD}@${T_DB_SERVICE_NAME_DEV}-client.development.svc.cluster.local:5432/${T_DB_NAME_DEV}"
  ${KUBECTL} -n development create secret generic backend-db-connection --from-literal=DB_URI="${DB_URI_DEV}" --dry-run=client -o yaml > "$TMPDIR/backend-db-connection-dev.yaml" || true
  ${KUBECTL} apply -f "$TMPDIR/backend-db-connection-dev.yaml" || true

  DB_URI_PROD="postgresql://${T_DB_USER}:${DB_PASSWORD}@${T_DB_SERVICE_NAME_PROD}-client.default.svc.cluster.local:5432/${T_DB_NAME_PROD}"
  ${KUBECTL} -n default create secret generic backend-db-connection --from-literal=DB_URI="${DB_URI_PROD}" --dry-run=client -o yaml > "$TMPDIR/backend-db-connection-prod.yaml" || true
  ${KUBECTL} apply -f "$TMPDIR/backend-db-connection-prod.yaml" || true
}

bootstrap_argocd_apps() {
  KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  export KUBECONFIG
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
  ensure_argocd_ingress_and_server
  generate_secrets_and_credentials
  bootstrap_argocd_apps
}

main "$@"
