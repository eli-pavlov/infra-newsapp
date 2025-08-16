#!/bin/bash
# ASCII-only; cleaned. Installs K3s servers. First server cluster-inits; others join.
set -euo pipefail

check_os() {
  name=$(grep ^NAME= /etc/os-release | sed 's/"//g')
  clean_name=${name#*=}
  version=$(grep ^VERSION_ID= /etc/os-release | sed 's/"//g')
  clean_version=$${version#*=}
  major=$${clean_version%.*}
  minor=$${clean_version#*.}

  if [[ "$clean_name" == "Ubuntu" ]]; then
    operating_system="ubuntu"
  elif [[ "$clean_name" == "Oracle Linux Server" ]]; then
    operating_system="oraclelinux"
  else
    operating_system="undef"
  fi

  echo "K3s server install:"
  echo "  OS: $operating_system"
  echo "  OS Major: $major"
  echo "  OS Minor: $minor"
}

install_base_packages() {
  if [[ "$operating_system" == "ubuntu" ]]; then
    /usr/sbin/netfilter-persistent stop || true
    /usr/sbin/netfilter-persistent flush || true
    systemctl disable --now netfilter-persistent.service || true
    apt-get update
    apt-get install -y software-properties-common jq curl python3 python3-pip nginx python3-jinja2 libnginx-mod-stream
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    systemctl enable nginx
    pip3 install --no-cache-dir oci-cli
  elif [[ "$operating_system" == "oraclelinux" ]]; then
    systemctl disable --now firewalld || true
    echo '(allow iptables_t cgroup_t (dir (ioctl)))' > /root/local_iptables.cil
    semodule -i /root/local_iptables.cil || true
    dnf -y update
    if [[ $major -eq 9 ]]; then
      dnf -y install oraclelinux-developer-release-el9
      dnf -y install jq curl python39-oci-cli python3-jinja2 nginx-all-modules
    else
      dnf -y install oraclelinux-developer-release-el8
      dnf -y module enable python36:3.6 nginx:1.20
      dnf -y install jq curl python36-oci-cli python3-jinja2 nginx-all-modules
    fi
    setsebool httpd_can_network_connect on -P || true
  fi

  echo "SystemMaxUse=100M" >> /etc/systemd/journald.conf
  echo "SystemMaxFileSize=100M" >> /etc/systemd/journald.conf
  systemctl restart systemd-journald || true
}

wait_lb() {
  while true; do
    curl --output /dev/null --silent -k https://${k3s_url}:6443 && break
    sleep 5
    echo "Waiting for LB at ${k3s_url}:6443"
  done
}

# Optional nginx stream config for proxy protocol to NodePorts (only if nginx ingress)
proxy_protocol_nginx() {
  cat > /root/nginx-header.tpl <<'EOT'
load_module modules/ngx_stream_module.so;

user www-data;
worker_processes auto;
pid /run/nginx.pid;
EOT

  cat > /root/nginx-footer.tpl <<'EOT'
events { worker_connections 768; }

stream {
  upstream k3s-http {
    # filled by render_nginx_config.py
  }
  upstream k3s-https {
    # filled by render_nginx_config.py
  }

  log_format basic '$remote_addr [$time_local] $protocol $status '
                   '$bytes_sent $bytes_received $session_time "$upstream_addr" '
                   '"$upstream_bytes_sent" "$upstream_bytes_received" "$upstream_connect_time"';

  access_log /var/log/nginx/k3s_access.log basic;
  error_log  /var/log/nginx/k3s_error.log;

  server {
    listen 443;
    proxy_pass k3s-https;
    proxy_next_upstream on;
    proxy_protocol on;
  }
  server {
    listen 80;
    proxy_pass k3s-http;
    proxy_next_upstream on;
    proxy_protocol on;
  }
}
EOT

  cat /root/nginx-header.tpl /root/nginx-footer.tpl > /root/nginx.tpl

  cat > /root/render_nginx_config.py <<'PY'
from jinja2 import Template
import os

ips_file = '/tmp/private_ips'
with open(ips_file) as f:
    ips = [line.strip() for line in f if line.strip()]

http_port = os.environ.get('HTTP_NODEPORT')
https_port = os.environ.get('HTTPS_NODEPORT')

with open('/root/nginx.tpl') as f:
    tpl = Template(f.read())

up_http = '\n'.join([f'    server {ip}:{http_port} max_fails=3 fail_timeout=10s;' for ip in ips])
up_https = '\n'.join([f'    server {ip}:{https_port} max_fails=3 fail_timeout=10s;' for ip in ips])

cfg = tpl.replace('# filled by render_nginx_config.py', up_http, 1)
cfg = cfg.replace('# filled by render_nginx_config.py', up_https, 1)

with open('/etc/nginx/nginx.conf', 'w') as f:
    f.write(cfg)
PY

  export OCI_CLI_AUTH=instance_principal
  : > /tmp/private_ips
  # list servers and workers in compartment, capture private IPs
  instance_ocids=$(oci search resource structured-search --query-text "QUERY instance resources where lifeCycleState='RUNNING' AND compartmentId='${compartment_ocid}'" --query 'data.items[*].identifier' --raw-output | jq -r '.[]')
  for ocid in ${instance_ocids}; do
    name=$(oci compute instance get --instance-id "$ocid" --raw-output --query 'data."display-name"')
    if [[ "$name" == *"k3s-servers"* || "$name" == *"k3s-workers"* ]]; then
      priv=$(oci compute instance list-vnics --instance-id "$ocid" --raw-output --query 'data[0]."private-ip"')
      echo "$priv" >> /tmp/private_ips
    fi
  done

  HTTP_NODEPORT="${ingress_controller_http_nodeport}" HTTPS_NODEPORT="${ingress_controller_https_nodeport}" python3 /root/render_nginx_config.py
  nginx -t
  systemctl restart nginx
}

install_helm() {
  curl -fsSL -o /root/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod 700 /root/get_helm.sh
  /root/get_helm.sh
}

install_argocd() {
  kubectl create namespace argocd || true
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
}

install_prometheus_stack() {
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo update
  helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack --namespace monitoring --create-namespace
}

install_postgresql() {
  helm repo add bitnami https://charts.bitnami.com/bitnami
  helm repo update
  POSTGRES_USER="newsappuser"
  POSTGRES_PASSWORD="$(openssl rand -hex 16)"
  POSTGRES_DB="newsappdb"
  kubectl create namespace database || true
  kubectl create secret generic postgres-secret \
    --from-literal=postgres-user="$POSTGRES_USER" \
    --from-literal=postgres-password="$POSTGRES_PASSWORD" \
    --from-literal=postgres-db="$POSTGRES_DB" \
    -n database \
    --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install postgres bitnami/postgresql \
    --namespace database \
    --set global.postgresql.auth.username="$POSTGRES_USER" \
    --set global.postgresql.auth.password="$POSTGRES_PASSWORD" \
    --set global.postgresql.auth.database="$POSTGRES_DB" \
    --set primary.service.type=ClusterIP
}

wait_for_postgres() {
  kubectl -n database rollout status statefulset/postgres-postgresql --timeout=600s || true
}

create_db_uri_secret() {
  if [[ -z "${POSTGRES_USER:-}" || -z "${POSTGRES_PASSWORD:-}" || -z "${POSTGRES_DB:-}" ]]; then
    POSTGRES_USER=$(kubectl -n database get secret postgres-secret -o jsonpath='{.data.postgres-user}' | base64 -d)
    POSTGRES_PASSWORD=$(kubectl -n database get secret postgres-secret -o jsonpath='{.data.postgres-password}' | base64 -d)
    POSTGRES_DB=$(kubectl -n database get secret postgres-secret -o jsonpath='{.data.postgres-db}' | base64 -d)
  fi
  DB_URI="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres-postgresql.database.svc.cluster.local/${POSTGRES_DB}"
  kubectl create namespace default || true
  kubectl create secret generic app-db-connection \
    --from-literal=DB_ENGINE_TYPE=POSTGRES \
    --from-literal=DB_URI="$DB_URI" \
    -n default \
    --dry-run=client -o yaml | kubectl apply -f -
}

create_ingress_routes() {
  if [[ "${ingress_controller}" == "nginx" ]]; then
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
  fi
}

wait_rollouts_basic() {
  kubectl -n argocd rollout status deploy/argocd-server --timeout=600s || true
  kubectl -n monitoring rollout status deploy/kube-prometheus-stack-operator --timeout=600s || true
  kubectl -n monitoring rollout status deploy/kube-prometheus-stack-grafana  --timeout=600s || true
}

# Main
check_os
install_base_packages

# Build K3s install params
k3s_install_params=()

%{ if k3s_subnet != "default_route_table" }
local_ip=$(ip -4 route ls ${k3s_subnet} | grep -Po '(?<=src )(\S+)')
flannel_iface=$(ip -4 route ls ${k3s_subnet} | grep -Po '(?<=dev )(\S+)')
k3s_install_params+=("--node-ip $local_ip")
k3s_install_params+=("--flannel-iface $flannel_iface")
%{ endif }

if [[ "$operating_system" == "oraclelinux" ]]; then
  k3s_install_params+=("--selinux")
fi

%{ if disable_ingress }
k3s_install_params+=("--disable traefik")
%{ else }
%{ if ingress_controller != "default" }
k3s_install_params+=("--disable traefik")
%{ endif }
%{ endif }

%{ if expose_kubeapi }
k3s_install_params+=("--tls-san ${k3s_tls_san_public}")
%{ endif }

k3s_install_params+=("--tls-san ${k3s_tls_san}")

INSTALL_PARAMS="${k3s_install_params[*]}"

%{ if k3s_version == "latest" }
K3S_VERSION=$(curl --silent https://api.github.com/repos/k3s-io/k3s/releases/latest | jq -r '.name')
%{ else }
K3S_VERSION="${k3s_version}"
%{ endif }

# Determine first server by display-name order within the compartment
export OCI_CLI_AUTH=instance_principal
first_server_name=$(oci compute instance list --compartment-id ${compartment_ocid} --availability-domain ${availability_domain} --lifecycle-state RUNNING --sort-by TIMECREATED | jq -r '.data[] | select(."display-name" | endswith("k3s-servers")) | .["display-name"]' | head -n 1 || true)
this_name=$(curl -s -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance | jq -r '.displayName')

if [[ "$first_server_name" == "$this_name" ]]; then
  # Cluster init
  until (curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" K3S_TOKEN=${k3s_token} sh -s - server --cluster-init $INSTALL_PARAMS); do
    echo "k3s server (cluster-init) did not install correctly"
    sleep 2
  done

  # Optional features and ingress
  %{ if install_longhorn }
  if [[ "$operating_system" == "ubuntu" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y open-iscsi curl util-linux
  fi
  systemctl enable --now iscsid.service || true
  kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/${longhorn_release}/deploy/longhorn.yaml
  %{ endif }

  %{ if ! disable_ingress }
  %{ if ingress_controller == "nginx" }
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-${nginx_ingress_release}/deploy/static/provider/baremetal/deploy.yaml
  kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s || true
  proxy_protocol_nginx
  %{ endif }
  %{ endif }

  install_helm
  install_postgresql
  wait_for_postgres
  create_db_uri_secret
  install_argocd
  install_prometheus_stack
  create_ingress_routes
  wait_rollouts_basic

else
  # Joining server
  wait_lb
  until (curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" K3S_TOKEN=${k3s_token} K3S_URL=https://${k3s_url}:6443 sh -s - server $INSTALL_PARAMS); do
    echo "k3s server (join) did not install correctly"
    sleep 2
  done
fi
