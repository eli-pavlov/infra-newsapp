#!/bin/bash
# K3s SERVER install (cluster-init on the control-plane node).
set -euo pipefail

# ------- Vars injected by Terraform (strings only) -------
T_K3S_VERSION="${k3s_version}"
T_K3S_SUBNET="${k3s_subnet}"
T_K3S_TOKEN="${k3s_token}"
T_K3S_URL="https://${k3s_url}:6443"
T_TLS_SAN_PRIV="${k3s_tls_san}"
T_TLS_SAN_PUB="${k3s_tls_san_public}"
T_DISABLE_INGRESS="${disable_ingress}"
T_INGRESS_CONTROLLER="${ingress_controller}"
T_NGINX_INGRESS_RELEASE="${nginx_ingress_release}"
T_HTTP_NODEPORT="${ingress_controller_http_nodeport}"
T_HTTPS_NODEPORT="${ingress_controller_https_nodeport}"
T_DB_MOUNT_PATH="${db_mount_path}"
T_DB_NODE_NAME="${node3_name}" # The name of the dedicated DB node

# ---------------------- Helpers --------------------------
detect_os() {
  local name version clean_name clean_version
  name=$(grep ^NAME= /etc/os-release | sed 's/"//g');   clean_name=$${name#*=}
  version=$(grep ^VERSION_ID= /etc/os-release | sed 's/"//g'); clean_version=$${version#*=}
  OS_MAJOR=$${clean_version%.*}
  OS_MINOR=$${clean_version#*.}
  if [[ "$clean_name" == "Ubuntu" ]]; then
    OS_FAMILY="ubuntu"
  elif [[ "$clean_name" == "Oracle Linux Server" ]]; then
    OS_FAMILY="oraclelinux"
  else
    OS_FAMILY="unknown"
  fi
  echo "Server install on: $OS_FAMILY $OS_MAJOR.$OS_MINOR"
}

base_setup() {
  if [[ "$OS_FAMILY" == "ubuntu" ]]; then
    /usr/sbin/netfilter-persistent stop || true
    /usr/sbin/netfilter-persistent flush || true
    systemctl disable --now netfilter-persistent.service || true
    apt-get update
    apt-get install -y jq curl software-properties-common
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  elif [[ "$OS_FAMILY" == "oraclelinux" ]]; then
    systemctl disable --now firewalld || true
    echo '(allow iptables_t cgroup_t (dir (ioctl)))' > /root/local_iptables.cil
    semodule -i /root/local_iptables.cil || true
    dnf -y update
    dnf -y install jq curl
  fi
  echo "SystemMaxUse=100M" >> /etc/systemd/journald.conf || true
  echo "SystemMaxFileSize=100M" >> /etc/systemd/journald.conf || true
  systemctl restart systemd-journald || true
}

install_helm() {
  if command -v helm >/dev/null 2>&1; then return; fi
  echo "Installing Helm..."
  curl -fsSL -o /root/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod +x /root/get_helm.sh
  /root/get_helm.sh
}

resolve_k3s_version() {
  if [[ "$T_K3S_VERSION" == "latest" ]]; then
    K3S_VERSION=$(curl --silent https://api.github.com/repos/k3s-io/k3s/releases/latest | jq -r '.name')
  else
    K3S_VERSION="$T_K3S_VERSION"
  fi
  echo "Using K3s version: $K3S_VERSION"
}

install_ingress_nginx_nodeport() {
  kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-$T_NGINX_INGRESS_RELEASE/deploy/static/provider/baremetal/deploy.yaml"
  cat > /root/nginx-ingress-nodeport.yaml <<YAML
---
apiVersion: v1
kind: Service
metadata:
  name: ingress-nginx-controller-loadbalancer
  namespace: ingress-nginx
spec:
  type: NodePort
  selector:
    app.kubernetes.io/component: controller
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
  ports:
    - name: http
      port: 80
      targetPort: 80
      nodePort: $T_HTTP_NODEPORT
      protocol: TCP
    - name: https
      port: 443
      targetPort: 443
      nodePort: $T_HTTPS_NODEPORT
      protocol: TCP
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
data:
  allow-snippet-annotations: "true"
  use-forwarded-headers: "true"
YAML
  kubectl apply -f /root/nginx-ingress-nodeport.yaml
}

install_argocd() {
  echo "Installing Argo CD..."
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  kubectl -n argocd rollout status deployment/argocd-server --timeout=600s || true
}

install_prometheus_stack() {
  echo "Installing Kube Prometheus Stack (Prometheus + Grafana)..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update || true
  helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace monitoring --create-namespace \
    --wait --timeout 20m
}

save_credentials() {
  echo "Saving credentials to /root/credentials.txt..."
  > /root/credentials.txt
  chmod 600 /root/credentials.txt

  # --- Argo CD ---
  ARGO_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
  echo "--- Argo CD ---" >> /root/credentials.txt
  echo "Username: admin" >> /root/credentials.txt
  echo "Password: $ARGO_PASS" >> /root/credentials.txt
  echo "" >> /root/credentials.txt

  # --- Grafana ---
  GRAFANA_PASS=$(kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 -d)
  echo "--- Grafana ---" >> /root/credentials.txt
  echo "Username: admin" >> /root/credentials.txt
  echo "Password: $GRAFANA_PASS" >> /root/credentials.txt
  echo "" >> /root/credentials.txt

  echo "Credentials saved successfully."
}


# --------------------- Main logic ------------------------
detect_os
base_setup
resolve_k3s_version

# Build K3s server install parameters
PARAMS="--tls-san $T_TLS_SAN_PRIV --tls-san $T_TLS_SAN_PUB"
if [[ "$T_K3S_SUBNET" != "default_route_table" ]]; then
  local_ip=$(ip -4 route ls "$T_K3S_SUBNET" | grep -Po '(?<=src )(\S+)' || true)
  flannel_iface=$(ip -4 route ls "$T_K3S_SUBNET" | grep -Po '(?<=dev )(\S+)' || true)
  if [[ -n "${local_ip:-}" ]]; then PARAMS="$PARAMS --node-ip $local_ip --advertise-address $local_ip"; fi
  if [[ -n "${flannel_iface:-}" ]]; then PARAMS="$PARAMS --flannel-iface $flannel_iface"; fi
fi
if [[ "$T_DISABLE_INGRESS" == "true" || "$T_INGRESS_CONTROLLER" == "nginx" ]]; then
  PARAMS="$PARAMS --disable traefik"
fi
if [[ "$OS_FAMILY" == "oraclelinux" ]]; then
  PARAMS="$PARAMS --selinux"
fi

# This is the first and only server, so we always do --cluster-init
echo "Initializing K3s cluster on control-plane..."
until (curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" K3S_TOKEN="$T_K3S_TOKEN" sh -s - server --cluster-init $PARAMS); do
  echo "k3s cluster-init failed, retrying..."
  sleep 5
done

# Wait for k3s to be usable
echo "Waiting for this node to be ready..."
until kubectl get nodes -A | grep -q 'Ready'; do
  sleep 5
done

# Install NGINX Ingress Controller if configured
if [[ "$T_DISABLE_INGRESS" != "true" && "$T_INGRESS_CONTROLLER" == "nginx" ]]; then
  install_ingress_nginx_nodeport
fi

echo "K3s control-plane setup complete."

# ---------------- PostgreSQL + durable block volume (LAST STEP) ----------------
echo "Setting up PostgreSQL instances with durable OCI Block Volume on node '$T_DB_NODE_NAME'..."

install_helm

# Helm repo (idempotent)
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
helm repo update || true

DB_NODE_NAME="$T_DB_NODE_NAME"
kubectl create namespace databases --dry-run=client -o yaml | kubectl apply -f -

# --- DATABASE #1 (Development) ---
echo "--> Deploying Development Database (dev-db)..."
PG_STORAGE_SIZE_1="30Gi"
PG_APP_USER_1="appuser_dev"
PG_APP_DB_1="appdb_dev"
PG_ROOT_PASSWORD_1="$(head -c 64 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 24)"
PG_APP_PWD_1="$(head -c 64 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 24)"
DB_MOUNT_PATH_1="$T_DB_MOUNT_PATH/dev" # Use a subdirectory for isolation

cat <<PV1 | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pg-hostpath-pv-dev
spec:
  capacity: { storage: $PG_STORAGE_SIZE_1 }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values: ["$DB_NODE_NAME"]
  hostPath: { path: "$DB_MOUNT_PATH_1" }
PV1

cat <<PVC1 | kubectl -n databases apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pg-hostpath-pvc-dev
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: $PG_STORAGE_SIZE_1 } }
  storageClassName: ""
  volumeName: pg-hostpath-pv-dev
PVC1

helm upgrade --install postgresql-dev bitnami/postgresql \
  --namespace databases \
  --set fullnameOverride=postgresql-dev \
  --set auth.enablePostgresUser=true \
  --set auth.postgresPassword="$PG_ROOT_PASSWORD_1" \
  --set auth.username="$PG_APP_USER_1" \
  --set auth.password="$PG_APP_PWD_1" \
  --set auth.database="$PG_APP_DB_1" \
  --set primary.persistence.enabled=true \
  --set primary.persistence.existingClaim=pg-hostpath-pvc-dev \
  --set primary.nodeSelector."kubernetes\.io/hostname"="$DB_NODE_NAME" \
  --wait --timeout 20m

# Create secret ONLY in the 'development' namespace
PG_HOST_1="postgresql-dev.databases.svc.cluster.local"
DB_URI_1="postgres://$PG_APP_USER_1:$PG_APP_PWD_1@$PG_HOST_1:5432/$PG_APP_DB_1"
kubectl create namespace development --dry-run=client -o yaml | kubectl apply -f -
kubectl -n development create secret generic backend-db-env \
  --from-literal=DB_ENGINE_TYPE=POSTGRES \
  --from-literal=DB_URI="$DB_URI_1" \
  --dry-run=client -o yaml | kubectl apply -f -

# --- DATABASE #2 (Production) ---
echo "--> Deploying Production Database (prod-db)..."
PG_STORAGE_SIZE_2="30Gi"
PG_APP_USER_2="appuser_prod"
PG_APP_DB_2="appdb_prod"
PG_ROOT_PASSWORD_2="$(head -c 64 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 24)"
PG_APP_PWD_2="$(head -c 64 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 24)"
DB_MOUNT_PATH_2="$T_DB_MOUNT_PATH/prod" # Use a different subdirectory

cat <<PV2 | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pg-hostpath-pv-prod
spec:
  capacity: { storage: $PG_STORAGE_SIZE_2 }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values: ["$DB_NODE_NAME"]
  hostPath: { path: "$DB_MOUNT_PATH_2" }
PV2

cat <<PVC2 | kubectl -n databases apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pg-hostpath-pvc-prod
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: $PG_STORAGE_SIZE_2 } }
  storageClassName: ""
  volumeName: pg-hostpath-pv-prod
PVC2

helm upgrade --install postgresql-prod bitnami/postgresql \
  --namespace databases \
  --set fullnameOverride=postgresql-prod \
  --set auth.enablePostgresUser=true \
  --set auth.postgresPassword="$PG_ROOT_PASSWORD_2" \
  --set auth.username="$PG_APP_USER_2" \
  --set auth.password="$PG_APP_PWD_2" \
  --set auth.database="$PG_APP_DB_2" \
  --set primary.persistence.enabled=true \
  --set primary.persistence.existingClaim=pg-hostpath-pvc-prod \
  --set primary.nodeSelector."kubernetes\.io/hostname"="$DB_NODE_NAME" \
  --wait --timeout 20m

# Create secret ONLY in the 'default' (production) namespace
PG_HOST_2="postgresql-prod.databases.svc.cluster.local"
DB_URI_2="postgres://$PG_APP_USER_2:$PG_APP_PWD_2@$PG_HOST_2:5432/$PG_APP_DB_2"
kubectl create namespace default --dry-run=client -o yaml | kubectl apply -f -
kubectl -n default create secret generic backend-db-env \
  --from-literal=DB_ENGINE_TYPE=POSTGRES \
  --from-literal=DB_URI="$DB_URI_2" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "PostgreSQL setup complete."

# ---------------- Install Cluster Tooling (Argo, Monitoring) ----------------
install_argocd
install_prometheus_stack

# ---------------- Save Credentials ----------------
save_credentials

echo "Cluster tooling installation and credential saving complete."
