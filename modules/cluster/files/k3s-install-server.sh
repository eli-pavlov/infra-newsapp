#!/bin/bash
# k3s-install-server.sh — control-plane bootstrap with Postgres, ArgoCD, Prometheus, Grafana

set -euo pipefail

check_os() {
  name=$(grep ^NAME= /etc/os-release | sed 's/"//g')
  clean_name=${name#*=}

  version=$(grep ^VERSION_ID= /etc/os-release | sed 's/"//g')
  clean_version=${version#*=}
  major=${clean_version%.*}
  minor=${clean_version#*.}

  if [[ "$clean_name" == "Ubuntu" ]]; then
    operating_system="ubuntu"
  elif [[ "$clean_name" == "Oracle Linux Server" ]]; then
    operating_system="oraclelinux"
  else
    operating_system="undef"
  fi

  echo "K3S install process running on:"
  echo "  OS: $operating_system"
  echo "  Major: $major  Minor: $minor"
}

wait_lb() {
  while true; do
    curl --output /dev/null --silent -k https://${k3s_url}:6443 && break
    sleep 5
    echo "wait for LB"
  done
}

install_helm() {
  if ! command -v helm >/dev/null 2>&1; then
    curl -fsSL -o /root/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 /root/get_helm.sh
    /root/get_helm.sh
  fi
}

render_nginx_config(){
cat << EOF > "$NGINX_RESOURCES_FILE"
---
apiVersion: v1
kind: Service
metadata:
  name: ingress-nginx-controller-loadbalancer
  namespace: ingress-nginx
spec:
  selector:
    app.kubernetes.io/component: controller
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
  ports:
    - name: http
      port: 80
      protocol: TCP
      targetPort: 80
      nodePort: ${ingress_controller_http_nodeport}
    - name: https
      port: 443
      protocol: TCP
      targetPort: 443
      nodePort: ${ingress_controller_https_nodeport}
  type: NodePort
---
apiVersion: v1
data:
  allow-snippet-annotations: "true"
  enable-real-ip: "true"
  proxy-real-ip-cidr: "0.0.0.0/0"
  proxy-body-size: "20m"
  use-proxy-protocol: "true"
kind: ConfigMap
metadata:
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/name: ingress-nginx
    app.kubernetes.io/part-of: ingress-nginx
  name: ingress-nginx-controller
  namespace: ingress-nginx
EOF
}

install_and_configure_nginx(){
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-${nginx_ingress_release}/deploy/static/provider/baremetal/deploy.yaml
  NGINX_RESOURCES_FILE=/root/nginx-ingress-resources.yaml
  render_nginx_config
  kubectl apply -f "$NGINX_RESOURCES_FILE"
}

install_ingress(){
  INGRESS_CONTROLLER=$1
  if [[ "$INGRESS_CONTROLLER" == "nginx" ]]; then
    install_and_configure_nginx
  else
    echo "Ingress controller not supported"
  fi
}

# --- Addons: DB, GitOps, Monitoring ---

install_postgresql_and_connection_secret(){
  echo "[addons] Installing PostgreSQL (ClusterIP) and creating DB connection Secrets"
  # Helm repo
  helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null
  helm repo update >/dev/null

  kubectl create namespace database --dry-run=client -o yaml | kubectl apply -f -
  kubectl create namespace developments --dry-run=client -o yaml | kubectl apply -f -

  # Create DB creds (user/pass/db). Keep values also in credentials file later.
  POSTGRES_USER="appuser"
  POSTGRES_PASSWORD="$(openssl rand -hex 16)"
  POSTGRES_DB="appdb"

  # Install Bitnami PostgreSQL as ClusterIP
  helm upgrade --install postgres bitnami/postgresql \
    --namespace database \
    --set global.postgresql.auth.username="$POSTGRES_USER" \
    --set global.postgresql.auth.password="$POSTGRES_PASSWORD" \
    --set global.postgresql.auth.database="$POSTGRES_DB" \
    --set primary.service.type=ClusterIP \
    --wait

  # Wait for statefulset ready (defensive)
  kubectl -n database rollout status statefulset/postgres-postgresql --timeout=10m || true

  # Build connection string: postgresql://user:pass@svc.database.svc.cluster.local/db
  PG_SVC_HOST="postgres-postgresql.database.svc.cluster.local"
  DB_URI="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${PG_SVC_HOST}/${POSTGRES_DB}"

  # Create the Secret (DB_ENGINE_TYPE + DB_URI) in default and developments
  for ns in default developments; do
    kubectl -n "$ns" create secret generic app-db-connection \
      --from-literal=DB_ENGINE_TYPE=POSTGRES \
      --from-literal=DB_URI="$DB_URI" \
      --dry-run=client -o yaml | kubectl apply -f -
  done

  # Also store the raw DB creds in database namespace for ops (optional)
  kubectl -n database create secret generic postgres-plain-creds \
    --from-literal=POSTGRES_USER="$POSTGRES_USER" \
    --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
    --from-literal=POSTGRES_DB="$POSTGRES_DB" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Export values for credentials file
  export _DB_USER="$POSTGRES_USER" _DB_PASS="$POSTGRES_PASSWORD" _DB_NAME="$POSTGRES_DB" _DB_URI="$DB_URI"
}

install_argocd_prometheus_grafana(){
  echo "[addons] Installing Argo CD + kube-prometheus-stack (Prometheus + Grafana) with control-plane affinity"

  install_helm

  # Affinity/tolerations for control-plane scheduling (works with both 'master' and 'control-plane' labels)
  cat > /root/affinity-tolerations.yaml <<'YAML'
tolerations:
  - key: "node-role.kubernetes.io/master"
    operator: "Exists"
    effect: "NoSchedule"
  - key: "node-role.kubernetes.io/control-plane"
    operator: "Exists"
    effect: "NoSchedule"
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
      - matchExpressions:
        - key: node-role.kubernetes.io/master
          operator: Exists
YAML

  # ---- Argo CD
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
  helm repo update >/dev/null
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

  # Build Argo CD values to inject affinity/tolerations to all components
  cat > /root/values-argocd.yaml <<'YAML'
# Apply to all components
controller:
  extraArgs: []
  {{- /* injected below */ -}}
server:
  extraArgs: []
repoServer: {}
dex: {}
redis: {}
# Placeholders; real blocks appended below
YAML

  # Append the shared affinity/tolerations to each Argo CD component
  for comp in controller server repoServer dex redis; do
    echo "${comp}:" >> /root/values-argocd.yaml
    sed 's/^/  /' /root/affinity-tolerations.yaml >> /root/values-argocd.yaml
  done

  helm upgrade --install argocd argo/argo-cd \
    -n argocd \
    -f /root/values-argocd.yaml \
    --wait

  # Ingress for Argo CD (HTTP via nginx ingress; TLS termination upstream)
  cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /argocd
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 80
EOF

  # ---- kube-prometheus-stack (Prometheus + Grafana)
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
  helm repo update >/dev/null
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

  cat > /root/values-kps.yaml <<'YAML'
grafana:
  adminUser: admin
  # password will be autogenerated & kept in secret; we'll read it later
  service:
    type: ClusterIP
  ingress:
    enabled: false
  # Schedule to control-plane
YAML
  echo "grafana:" >> /root/values-kps.yaml
  sed 's/^/  /' /root/affinity-tolerations.yaml >> /root/values-kps.yaml

  cat >> /root/values-kps.yaml <<'YAML'
prometheus:
  service:
    type: ClusterIP
  prometheusSpec:
    # Schedule to control-plane
    tolerations:
      - key: "node-role.kubernetes.io/master"
        operator: "Exists"
        effect: "NoSchedule"
      - key: "node-role.kubernetes.io/control-plane"
        operator: "Exists"
        effect: "NoSchedule"
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
          - matchExpressions:
            - key: node-role.kubernetes.io/control-plane
              operator: Exists
          - matchExpressions:
            - key: node-role.kubernetes.io/master
              operator: Exists
alertmanager:
  alertmanagerSpec:
    tolerations:
      - key: "node-role.kubernetes.io/master"
        operator: "Exists"
        effect: "NoSchedule"
      - key: "node-role.kubernetes.io/control-plane"
        operator: "Exists"
        effect: "NoSchedule"
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
          - matchExpressions:
            - key: node-role.kubernetes.io/control-plane
              operator: Exists
          - matchExpressions:
            - key: node-role.kubernetes.io/master
              operator: Exists
YAML

  helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    -n monitoring \
    -f /root/values-kps.yaml \
    --wait

  # Ingress for Grafana (HTTP via nginx ingress)
  cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: monitoring
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /grafana
        pathType: Prefix
        backend:
          service:
            name: kube-prometheus-stack-grafana
            port:
              number: 80
EOF

  # Collect credentials to /root/control-plane-credentials.txt
  echo "[addons] Writing credentials to /root/control-plane-credentials.txt"

  # ArgoCD admin password (from secret)
  ARGO_PWD="$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"

  # Grafana admin password (from chart secret)
  GRAFANA_PWD="$(kubectl -n monitoring get secret kube-prometheus-stack-grafana \
    -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || true)"

  # Save credentials (plus DB info exported earlier)
  cat > /root/control-plane-credentials.txt <<CREDS
=== K3s Addons Credentials ===
Generated: $(date -u)

[PostgreSQL]
Namespace: database
Service FQDN: postgres-postgresql.database.svc.cluster.local
Username: ${_DB_USER:-N/A}
Password: ${_DB_PASS:-N/A}
Database: ${_DB_NAME:-N/A}
DB_URI:    ${_DB_URI:-N/A}
Secrets (for apps):
  - default/app-db-connection
  - developments/app-db-connection
Keys:
  - DB_ENGINE_TYPE=POSTGRES
  - DB_URI=<above>

[Argo CD]
Namespace: argocd
URL path (via ingress-nginx): /argocd
Username: admin
Password: ${ARGO_PWD:-<not-ready-yet>}

[Grafana]
Namespace: monitoring
URL path (via ingress-nginx): /grafana
Username: admin
Password: ${GRAFANA_PWD:-<not-ready-yet>}

[Prometheus]
Namespace: monitoring
Notes: Default UI has no auth; exposed as ClusterIP.
CREDS
  chmod 600 /root/control-plane-credentials.txt
}

create_ingress_routes(){
  # (kept for backward compatibility; now created inside installers)
  :
}

# ----------------- Main flow -----------------

check_os

if [[ "$operating_system" == "ubuntu" ]]; then
  # Disable firewall
  /usr/sbin/netfilter-persistent stop || true
  /usr/sbin/netfilter-persistent flush || true
  systemctl disable --now netfilter-persistent.service || true

  apt-get update
  apt-get install -y software-properties-common jq curl
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y python3 python3-pip
  pip install --no-cache-dir oci-cli

  echo "SystemMaxUse=100M" >> /etc/systemd/journald.conf
  echo "SystemMaxFileSize=100M" >> /etc/systemd/journald.conf
  systemctl restart systemd-journald || true
fi

if [[ "$operating_system" == "oraclelinux" ]]; then
  # Disable firewall
  systemctl disable --now firewalld || true

  # Fix iptables/SELinux bug
  echo '(allow iptables_t cgroup_t (dir (ioctl)))' > /root/local_iptables.cil
  semodule -i /root/local_iptables.cil || true

  dnf -y update
  if [[ $major -eq 9 ]]; then
    dnf -y install oraclelinux-developer-release-el9
    dnf -y install jq python39-oci-cli curl
  else
    dnf -y install oraclelinux-developer-release-el8
    dnf -y module enable python36:3.6
    dnf -y install jq python36-oci-cli curl
  fi
fi

export OCI_CLI_AUTH=instance_principal
first_instance=$(oci compute instance list --compartment-id ${compartment_ocid} --availability-domain ${availability_domain} --lifecycle-state RUNNING --sort-by TIMECREATED  | jq -r '.data[]|select(."display-name" | endswith("k3s-servers")) | .["display-name"]' | tail -n 1)
instance_id=$(curl -s -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance | jq -r '.displayName')

k3s_install_params=("--tls-san ${k3s_tls_san}")

%{ if k3s_subnet != "default_route_table" }
local_ip=$(ip -4 route ls ${k3s_subnet} | grep -Po '(?<=src )(\S+)')
flannel_iface=$(ip -4 route ls ${k3s_subnet} | grep -Po '(?<=dev )(\S+)')
k3s_install_params+=("--node-ip $local_ip")
k3s_install_params+=("--advertise-address $local_ip")
k3s_install_params+=("--flannel-iface $flannel_iface")
%{ endif }

%{ if disable_ingress }
k3s_install_params+=("--disable traefik")
%{ endif }

%{ if ! disable_ingress }
%{ if ingress_controller != "default" }
k3s_install_params+=("--disable traefik")
%{ endif }
%{ endif }

%{ if expose_kubeapi }
k3s_install_params+=("--tls-san ${k3s_tls_san_public}")
%{ endif }

if [[ "$operating_system" == "oraclelinux" ]]; then
  k3s_install_params+=("--selinux")
fi

INSTALL_PARAMS="${k3s_install_params[*]}"

%{ if k3s_version == "latest" }
K3S_VERSION=$(curl --silent https://api.github.com/repos/k3s-io/k3s/releases/latest | jq -r '.name')
%{ else }
K3S_VERSION="${k3s_version}"
%{ endif }

if [[ "$first_instance" == "$instance_id" ]]; then
  echo "[k3s] First server: cluster-init"
  until (curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" K3S_TOKEN=${k3s_token} sh -s - --cluster-init $INSTALL_PARAMS); do
    echo 'k3s did not install correctly'
    sleep 2
  done
else
  echo "[k3s] Joining existing server"
  wait_lb
  until (curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" K3S_TOKEN=${k3s_token} sh -s - --server https://${k3s_url}:6443 $INSTALL_PARAMS); do
    echo 'k3s did not install correctly'
    sleep 2
  done
fi

%{ if is_k3s_server }
until kubectl get pods -A | grep 'Running' >/dev/null 2>&1; do
  echo '[k3s] Waiting for startup'
  sleep 5
done

# Optional Longhorn
%{ if install_longhorn }
if [[ "$first_instance" == "$instance_id" ]]; then
  if [[ "$operating_system" == "ubuntu" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y open-iscsi curl util-linux
  fi
  systemctl enable --now iscsid.service || true
  kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/${longhorn_release}/deploy/longhorn.yaml
fi
%{ endif }

# Ingress controller (if requested)
%{ if ! disable_ingress }
%{ if ingress_controller != "default" }
if [[ "$first_instance" == "$instance_id" ]]; then
  install_ingress ${ingress_controller}
fi
%{ endif }
%{ endif }

# Install addons only on the first server
if [[ "$first_instance" == "$instance_id" ]]; then
  install_postgresql_and_connection_secret
  install_argocd_prometheus_grafana
fi

%{ endif }

echo "[done] Bootstrap complete."
