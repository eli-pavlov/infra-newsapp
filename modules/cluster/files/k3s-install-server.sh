#!/bin/bash
# K3s SERVER install, tooling, secret generation, ingress-nginx install,
# and Argo CD bootstrapping.
# Converted for Oracle Linux 9 (dnf-based) — keep minimal & robust.
set -euo pipefail
# Simpler robust logging (avoid SIGPIPE issues of tee|logger chain)
exec > /var/log/cloud-init-output.log 2>&1
# Report failing command with line number
trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR

# --- Vars injected by Terraform (these are template vars replaced by templatefile) ---
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

set -x

install_base_tools() {
  echo "Installing base packages (dnf)..."
  dnf makecache --refresh -y || true
  dnf update -y
  dnf install -y curl jq git || true
}

# tolerate systems without firewalld installed
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
  # Use runtime shell vars for things that were template-injected at the top
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
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm repo update
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
    --set controller.ingressClassByName=true

  /usr/local/bin/kubectl -n ingress-nginx rollout status ds/ingress-nginx-controller --timeout=5m || true
}

install_argo_cd() {
  echo "Installing Argo CD..."
  /usr/local/bin/kubectl create namespace argocd --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f - || true
  /usr/local/bin/kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

  # add tolerations as in original script
  for d in argocd-server argocd-repo-server argocd-dex-server; do
    /usr/local/bin/kubectl -n argocd patch deployment "$d" --type='json' -p='[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}]' || true
  done
  /usr/local/bin/kubectl -n argocd patch statefulset argocd-application-controller --type='json' -p='[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}]' || true

  echo "Waiting for Argo CD deployments to be available..."
  # wait loops instead of strict single command so we can tolerate transient failures
  local timeout=300; local start=$(date +%s)
  while true; do
    if /usr/local/bin/kubectl -n argocd get deploy -o name | xargs -r -n1 /usr/local/bin/kubectl -n argocd rollout status --timeout=10s; then
      echo "Argo CD deployments appear ready (best-effort)."
      break
    fi
    if [ $(( $(date +%s) - start )) -gt $timeout ]; then
      echo "Timeout waiting for ArgoCD deployments; continuing (some components may still be initializing)."
      break
    fi
    sleep 5
  done
}

ensure_argocd_ingress_and_server() {
  set -euo pipefail
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  kubectl -n argocd apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server-ingress
  namespace: argocd
  annotations:
    kubernetes.io/ingress.class: "nginx"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
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

  # Keep existing annotate/patch style from your original script
  kubectl -n argocd annotate ingress argocd-server-ingress nginx.ingress.kubernetes.io/backend-protocol='HTTPS' --overwrite >/dev/null || true

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

  # Use escaped/quoted cert args so Terraform won't try to process them; shell will expand at runtime
  if [[ -n "$${CERT_FILE:-}" && -n "$${KEY_FILE:-}" ]]; then
    /usr/local/bin/kubectl -n argocd create secret tls argocd-tls \
      --cert="$${CERT_FILE}" --key="$${KEY_FILE}" --dry-run=client -o yaml > "/tmp/argocd-tls.yaml" && \
    /usr/local/bin/kubectl apply -f "/tmp/argocd-tls.yaml" || true
    echo "Created/updated argocd-tls secret from provided CERT_FILE/KEY_FILE."
  else
    echo "CERT_FILE/KEY_FILE not set — not creating TLS secret."
  fi

  kubectl -n argocd patch configmap argocd-cm --type=merge -p '{"data":{"url":"https://argocd.weblightenment.com"}}' || true
  kubectl -n argocd rollout restart deployment argocd-server || true

  echo "Ingress/annotations applied and argocd-server restarted."
}

add_connected_repositories() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo "Creating repository secrets in argocd namespace..."

  # 1) Add your manifests repo as an argocd repository secret (public or private)
  /usr/local/bin/kubectl -n argocd apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: newsapp-manifests
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: $T_MANIFESTS_REPO_URL
EOF

  # 2) Add Jetstack helm repo as a repo secret (so ArgoCD can fetch cert-manager chart)
  /usr/local/bin/kubectl -n argocd apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: jetstack-helm
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: helm
  url: https://charts.jetstack.io
EOF

  echo "Repository secrets applied."
}

generate_secrets_and_credentials() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  sleep 30
  echo "Generating credentials and Kubernetes secrets..."

  DB_PASSWORD=$(python3 - <<'PY'
import secrets,string
print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(32)))
PY
)

  # Wait until ArgoCD initial admin secret is present, then extract password.
  local timeout=120; local start=$(date +%s)
  while true; do
    if /usr/local/bin/kubectl -n argocd get secret argocd-initial-admin-secret >/dev/null 2>&1; then
      break
    fi
    if [ $(( $(date +%s) - start )) -gt $timeout ]; then
      echo "argocd-initial-admin-secret not found after waiting; continuing anyway."
      break
    fi
    sleep 3
  done

  ARGO_PASSWORD=$(/usr/local/bin/kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null || echo "" )
  if [ -n "$ARGO_PASSWORD" ]; then
    ARGO_PASSWORD=$(echo "$ARGO_PASSWORD" | base64 -d)
  else
    ARGO_PASSWORD="(unknown)"
  fi

  # Persist runtime credentials (use plain $VAR form so templatefile won't try to interpolate)
  cat << EOF > /root/credentials.txt
# --- Argo CD Admin Credentials ---
Username: admin
Password: $ARGO_PASSWORD
# --- PostgreSQL Database Credentials ---
Username: $T_DB_USER
Password: $DB_PASSWORD
EOF
  chmod 600 /root/credentials.txt
  echo "Credentials saved to /root/credentials.txt"

  for ns in default development; do
    /usr/local/bin/kubectl create namespace "$ns" --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f - || true
    /usr/local/bin/kubectl -n "$ns" create secret generic postgres-credentials \
      --from-literal=POSTGRES_USER="$T_DB_USER" \
      --from-literal=POSTGRES_PASSWORD="$DB_PASSWORD" \
      --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f - || true
  done

  # backend DB connection secrets expected by charts
  DB_URI_DEV="postgresql://$T_DB_USER:$DB_PASSWORD@$T_DB_SERVICE_NAME_DEV-client.development.svc.cluster.local:5432/$T_DB_NAME_DEV"
  /usr/local/bin/kubectl -n development create secret generic backend-db-connection \
    --from-literal=DB_URI="$DB_URI_DEV" --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f - || true

  DB_URI_PROD="postgresql://$T_DB_USER:$DB_PASSWORD@$T_DB_SERVICE_NAME_PROD-client.default.svc.cluster.local:5432/$T_DB_NAME_PROD"
  /usr/local/bin/kubectl -n default create secret generic backend-db-connection \
    --from-literal=DB_URI="$DB_URI_PROD" --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f - || true

  # Create cert-manager Cloudflare API token secret if token provided (optional for future DNS01)
  if [ -n "$T_CLOUDFLARE_API_TOKEN" ]; then
    echo "Creating cert-manager Cloudflare API token secret..."
    /usr/local/bin/kubectl create namespace cert-manager --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f - || true
    /usr/local/bin/kubectl -n cert-manager create secret generic cloudflare-api-token-secret \
      --from-literal=api-token="$T_CLOUDFLARE_API_TOKEN" --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f - || true
    echo "cloudflare-api-token-secret created/updated in cert-manager."
  else
    echo "T_CLOUDFLARE_API_TOKEN not set — skipping cert-manager Cloudflare secret creation."
  fi
}

bootstrap_argocd_apps() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo "Bootstrapping Argo CD Applications from manifests repo: $T_MANIFESTS_REPO_URL"

  # Ensure repo is cloned locally (robust against raw URL issues).
  TMP_MANIFESTS_DIR="/tmp/newsapp-manifests"
  if [ -d "$TMP_MANIFESTS_DIR/.git" ]; then
    echo "Local clone exists; attempting git -C pull..."
    git -C "$TMP_MANIFESTS_DIR" pull --ff-only || true
  else
    # clone, but do not fail cluster bootstrap if clone fails (let ArgoCD still be able to fetch via registered repo)
    if ! git clone --depth 1 "$T_MANIFESTS_REPO_URL" "$TMP_MANIFESTS_DIR"; then
      echo "Warning: git clone failed for $T_MANIFESTS_REPO_URL; continuing and attempting to apply remote raw manifests where possible."
    fi
  fi

  # Apply Project + stack Application CRs (dev & prod). Prefer local clone if available.
  set +e
  if [ -d "$TMP_MANIFESTS_DIR" ]; then
    kubectl -n argocd apply -f "${TMP_MANIFESTS_DIR}/clusters/dev/apps/project.yaml"
    kubectl -n argocd apply -f "${TMP_MANIFESTS_DIR}/clusters/dev/apps/stack.yaml"
    kubectl -n argocd apply -f "${TMP_MANIFESTS_DIR}/clusters/prod/apps/project.yaml"
    kubectl -n argocd apply -f "${TMP_MANIFESTS_DIR}/clusters/prod/apps/stack.yaml"
  else
    # Fallback: attempt raw.githubusercontent URLs (best-effort)
    # Try to convert possible GitHub HTTPS url to raw.githubusercontent pattern if it looks like github.com
    if echo "$T_MANIFESTS_REPO_URL" | grep -q 'github.com'; then
      base=$(echo "$T_MANIFESTS_REPO_URL" | sed -E 's#https://github.com/([^/]+/[^/]+)(.git)?#\1#')
      kubectl -n argocd apply -f "https://raw.githubusercontent.com/${base}/main/clusters/dev/apps/project.yaml" || true
      kubectl -n argocd apply -f "https://raw.githubusercontent.com/${base}/main/clusters/dev/apps/stack.yaml" || true
      kubectl -n argocd apply -f "https://raw.githubusercontent.com/${base}/main/clusters/prod/apps/project.yaml" || true
      kubectl -n argocd apply -f "https://raw.githubusercontent.com/${base}/main/clusters/prod/apps/stack.yaml" || true
    else
      echo "No local clone and not a GitHub URL; skipping direct apply of remote files (ArgoCD should be able to fetch manifests using the registered repository secret)."
    fi
  fi
  set -e

  # Wait for ArgoCD to reconcile new Applications (best-effort; tolerate the fact that ArgoCD may still be initializing)
  echo "Waiting up to 5m for applications to become Healthy (best-effort)..."
  /usr/local/bin/kubectl -n argocd wait --for=condition=Healthy application/newsapp-dev --timeout=5m || true
  /usr/local/bin/kubectl -n argocd wait --for=condition=Healthy application/newsapp-prod --timeout=5m || true

  echo "Argo CD Application CRs applied (from local clone or raw URLs)."
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
  add_connected_repositories
  generate_secrets_and_credentials
  bootstrap_argocd_apps
}

main "$@"
