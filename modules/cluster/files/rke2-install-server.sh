#!/bin/bash
# RKE2 SERVER install, tooling, secret generation, ingress-nginx install,
# and Argo CD bootstrapping.
# Converted for Oracle Linux 9 (dnf-based).
set -euo pipefail
exec > /var/log/cloud-init-output.log 2>&1
set -x
trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR

# --- Terraform-injected vars (kept as template placeholders for templatefile) ---
T_RKE2_VERSION="${T_RKE2_VERSION}"
T_RKE2_TOKEN="${T_RKE2_TOKEN}"
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
  dnf makecache --refresh -y || true
  dnf update -y
  dnf install -y curl jq git || true
}

# Best-effort disable firewalld (non-fatal)
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

install_rke2_server() {
  echo "Installing RKE2 server..."

  # Export installer/version variables (from Terraform-injected placeholders)
  INSTALL_RKE2_VERSION="$T_RKE2_VERSION"
  INSTALL_RKE2_EXEC="server"
  export INSTALL_RKE2_VERSION INSTALL_RKE2_EXEC

  mkdir -p /etc/rancher/rke2
  chmod 700 /etc/rancher/rke2

  # Write RKE2 config (use shell variables for runtime values)
  cat > /etc/rancher/rke2/config.yaml <<EOF
token: $T_RKE2_TOKEN
node-ip: $PRIVATE_IP
advertise-address: $PRIVATE_IP
write-kubeconfig-mode: "0644"
tls-san:
  - $PRIVATE_IP
  - $T_PRIVATE_LB_IP
node-taint:
  - "node-role.kubernetes.io/control-plane=true:NoSchedule"
kubelet-arg:
  - "register-with-taints=node-role.kubernetes.io/control-plane=true:NoSchedule"
EOF

  echo "Running RKE2 installer (version: $INSTALL_RKE2_VERSION)..."
  curl -sfL https://get.rke2.io | sh -

  systemctl enable --now rke2-server.service

  echo "Waiting for RKE2 server node to be Ready..."
  kubectl_bin=/var/lib/rancher/rke2/bin/kubectl
  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
  sudo ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl

  start_time=$(date +%s)
  timeout=900
  while true; do
    if [ -x "$kubectl_bin" ] && "$kubectl_bin" --kubeconfig=/etc/rancher/rke2/rke2.yaml get nodes 2>/dev/null | grep -q 'Ready'; then
      echo "RKE2 server node is Ready."
      break
    fi
    elapsed=$(( $(date +%s) - start_time ))
    if [ "$elapsed" -gt "$timeout" ]; then
      printf '❌ Timed out waiting for RKE2 server node to become Ready (elapsed %ds).\n' "$elapsed"
      "$kubectl_bin" --kubeconfig=/etc/rancher/rke2/rke2.yaml cluster-info || true
      journalctl -u rke2-server -n 200 --no-pager || true
      exit 1
    fi
    printf 'Waiting for node Ready... (%d/%d s)\n' "$elapsed" "$timeout"
    sleep 5
  done
}

wait_for_kubeconfig_and_api() {
  echo "Waiting for kubeconfig and API to be fully ready (RKE2)..."
  timeout=120
  start_time=$(date +%s)
  kubectl_bin=/var/lib/rancher/rke2/bin/kubectl

  while true; do
    if [ ! -f /etc/rancher/rke2/rke2.yaml ]; then
      echo "Waiting for /etc/rancher/rke2/rke2.yaml to be created..."
      sleep 5
      continue
    fi

    if "$kubectl_bin" --kubeconfig=/etc/rancher/rke2/rke2.yaml get nodes 2>/dev/null | grep -q 'Ready'; then
      if "$kubectl_bin" --kubeconfig=/etc/rancher/rke2/rke2.yaml get pods -n kube-system 2>/dev/null | grep -qE '(etcd|coredns|kube-proxy|kube-scheduler|kube-controller)'; then
        echo "✅ RKE2 kubeconfig and API are ready."
        break
      fi
    fi

    elapsed_time=$(( $(date +%s) - start_time ))
    if [ "$elapsed_time" -gt "$timeout" ]; then
      printf '❌ Timed out waiting for RKE2 kubeconfig and API readiness (%ds).\n' "$elapsed_time"
      "$kubectl_bin" --kubeconfig=/etc/rancher/rke2/rke2.yaml cluster-info || true
      exit 1
    fi

    printf '(%d/%d s) Waiting for RKE2 kubeconfig and API readiness...\n' "$elapsed_time" "$timeout"
    sleep 5
  done
}

wait_for_all_nodes() {
  echo "Waiting for all $T_EXPECTED_NODE_COUNT nodes to join and become Ready..."
  timeout=1800
  start_time=$(date +%s)
  while true; do
    ready_nodes=$(/usr/local/bin/kubectl get nodes --no-headers 2>/dev/null \
      | awk '{print $2}' | grep -Ec '^Ready(,SchedulingDisabled)?$' || true)
    if [ "$ready_nodes" -eq "$T_EXPECTED_NODE_COUNT" ]; then
      echo "✅ All $T_EXPECTED_NODE_COUNT nodes are Ready. Proceeding."
      break
    fi
    elapsed_time=$(( $(date +%s) - start_time ))
    if [ "$elapsed_time" -gt "$timeout" ]; then
      echo "❌ Timed out waiting for all nodes to become Ready."
      /usr/local/bin/kubectl get nodes || true
      exit 1
    fi
    printf '(%d/%d s) Currently %d/%s nodes are Ready. Waiting...\n' "$elapsed_time" "$timeout" "$ready_nodes" "$T_EXPECTED_NODE_COUNT"
    sleep 15
  done
}

install_helm() {
  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
  if ! command -v helm &> /dev/null; then
    echo "Installing Helm..."
    curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 /tmp/get_helm.sh
    /tmp/get_helm.sh
    rm -f /tmp/get_helm.sh
  fi
}

install_ingress_nginx() {
  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
  echo "Installing ingress-nginx via Helm (DaemonSet + NodePorts 30080/30443)..."
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

  echo "Waiting for ingress-nginx controller rollout..."
  /usr/local/bin/kubectl -n ingress-nginx rollout status ds/ingress-nginx-controller --timeout=5m
}

install_argo_cd() {
  echo "Installing Argo CD..."
  /usr/local/bin/kubectl create namespace argocd || true
  /usr/local/bin/kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

  # Tolerate control-plane taint where applicable
  for d in argocd-server argocd-repo-server argocd-dex-server; do
    /usr/local/bin/kubectl -n argocd patch deployment "$d" --type='json' -p='[
      {"op":"add","path":"/spec/template/spec/tolerations","value":[
        {"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}
      ]}
    ]' || true
  done

  /usr/local/bin/kubectl -n argocd patch statefulset argocd-application-controller --type='json' -p='[
    {"op":"add","path":"/spec/template/spec/tolerations","value":[
      {"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}
    ]}
  ]' || true

  echo "Waiting for Argo CD components to be ready..."
  /usr/local/bin/kubectl -n argocd wait --for=condition=Available deployments --all --timeout=5m || true
  /usr/local/bin/kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=5m || true
}

ensure_argocd_ingress_and_server() {
  set -euo pipefail
  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
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

  # NOTE: escape any shell parameter expansions that would be parsed by Terraform.
  # Use $${...} for shell expansions so templatefile() does not try to interpolate them.
  if [[ -n "$${CERT_FILE:-}" && -n "$${KEY_FILE:-}" ]]; then
    /usr/local/bin/kubectl -n argocd create secret tls argocd-tls \
      --cert="$CERT_FILE" --key="$KEY_FILE" --dry-run=client -o yaml > $${TMPDIR:-/tmp}/argocd-tls.yaml && \
    /usr/local/bin/kubectl apply -f $${TMPDIR:-/tmp}/argocd-tls.yaml || true
    echo "Created/updated argocd-tls secret from provided CERT_FILE/KEY_FILE."
  else
    echo "CERT_FILE/KEY_FILE not set — not creating TLS secret."
  fi

  kubectl -n argocd patch configmap argocd-cm --type=merge -p '{"data":{"url":"https://argocd.weblightenment.com"}}' || true
  kubectl -n argocd rollout restart deployment argocd-server || true

  echo "Ingress/annotations applied and argocd-server restarted."
}

generate_secrets_and_credentials() {
  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
  sleep 30
  echo "Generating credentials and Kubernetes secrets..."
  DB_PASSWORD=$(python3 -c 'import secrets, string; print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(32)))')

  # Now that we know the secret exists, get the password
  ARGO_PASSWORD=$(/usr/local/bin/kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

  cat <<EOF > /root/credentials.txt
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

  DB_URI_DEV="postgresql://$T_DB_USER:$DB_PASSWORD@${T_DB_SERVICE_NAME_DEV}-client.development.svc.cluster.local:5432/$T_DB_NAME_DEV"
  /usr/local/bin/kubectl -n development create secret generic backend-db-connection \
    --from-literal=DB_URI="$DB_URI_DEV" \
    --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f - || true

  DB_URI_PROD="postgresql://$T_DB_USER:$DB_PASSWORD@${T_DB_SERVICE_NAME_PROD}-client.default.svc.cluster.local:5432/$T_DB_NAME_PROD"
  /usr/local/bin/kubectl -n default create secret generic backend-db-connection \
    --from-literal=DB_URI="$DB_URI_PROD" \
    --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f - || true
}

bootstrap_argocd_apps() {
  echo "Bootstrapping Argo CD with applications from manifest repo..."
  rm -rf /tmp/manifests || true
  git clone "$T_MANIFESTS_REPO_URL" /tmp/manifests || true

  # DEV
  [ -f /tmp/manifests/clusters/dev/apps/project.yaml ] && /usr/local/bin/kubectl apply -f /tmp/manifests/clusters/dev/apps/project.yaml || true
  [ -f /tmp/manifests/clusters/dev/apps/stack.yaml ]   && /usr/local/bin/kubectl apply -f /tmp/manifests/clusters/dev/apps/stack.yaml   || true

  # PROD
  [ -f /tmp/manifests/clusters/prod/apps/project.yaml ] && /usr/local/bin/kubectl apply -f /tmp/manifests/clusters/prod/apps/project.yaml || true
  [ -f /tmp/manifests/clusters/prod/apps/stack.yaml ]   && /usr/local/bin/kubectl apply -f /tmp/manifests/clusters/prod/apps/stack.yaml   || true

  echo "Argo CD applications applied. Argo will now sync the cluster state."
}

main() {
  install_base_tools
  get_private_ip
  install_rke2_server
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
