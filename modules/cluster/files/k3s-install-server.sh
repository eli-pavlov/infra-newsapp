#!/bin/bash
# K3s SERVER install (cluster-init on first server, others join via PRIVATE LB).
# ASCII-only; Terraform only fills the top vars.
set -euo pipefail

# ------- Vars injected by Terraform (strings only) -------
T_K3S_VERSION="${k3s_version}"                     # "latest" or explicit version
T_K3S_SUBNET="${k3s_subnet}"
T_K3S_TOKEN="${k3s_token}"
T_COMPARTMENT_OCID="${compartment_ocid}"
T_AVAILABILITY_DOMAIN="${availability_domain}"

T_K3S_URL="https://${k3s_url}:6443"                # Private LB IP for API
T_TLS_SAN_PRIV="${k3s_tls_san}"                    # Usually the private LB IP
T_TLS_SAN_PUB="${k3s_tls_san_public}"              # Public NLB IP (if expose_kubeapi true)

T_DISABLE_INGRESS="${disable_ingress}"             # "true"/"false"
T_INGRESS_CONTROLLER="${ingress_controller}"       # "default" or "nginx"
T_NGINX_INGRESS_RELEASE="${nginx_ingress_release}" # e.g. v1.5.1
T_INSTALL_LONGHORN="${install_longhorn}"           # "true"/"false"
T_LONGHORN_RELEASE="${longhorn_release}"           # e.g. v1.4.2
T_EXPOSE_KUBEAPI="${expose_kubeapi}"               # "true"/"false"

T_HTTP_NODEPORT="${ingress_controller_http_nodeport}"   # 30080
T_HTTPS_NODEPORT="${ingress_controller_https_nodeport}" # 30443

# ---------------------- Helpers --------------------------
detect_os() {
  local name version clean_name clean_version
  name=$(grep ^NAME= /etc/os-release | sed 's/"//g');   clean_name=${name#*=}
  version=$(grep ^VERSION_ID= /etc/os-release | sed 's/"//g'); clean_version=${version#*=}
  OS_MAJOR=${clean_version%.*}
  OS_MINOR=${clean_version#*.}
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
    apt-get install -y jq curl software-properties-common python3 python3-pip
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    pip3 install --no-cache-dir oci-cli
  elif [[ "$OS_FAMILY" == "oraclelinux" ]]; then
    systemctl disable --now firewalld || true
    echo '(allow iptables_t cgroup_t (dir (ioctl)))' > /root/local_iptables.cil
    semodule -i /root/local_iptables.cil || true
    dnf -y update
    if [[ "$OS_MAJOR" -eq 9 ]]; then
      dnf -y install oraclelinux-developer-release-el9
      dnf -y install jq curl python39-oci-cli
    else
      dnf -y install oraclelinux-developer-release-el8
      dnf -y module enable python36:3.6
      dnf -y install jq curl python36-oci-cli
    fi
  fi
  echo "SystemMaxUse=100M" >> /etc/systemd/journald.conf || true
  echo "SystemMaxFileSize=100M" >> /etc/systemd/journald.conf || true
  systemctl restart systemd-journald || true
}

wait_for_api_lb() {
  echo "Waiting for LB $T_K3S_URL ..."
  while true; do
    curl --output /dev/null --silent -k "$T_K3S_URL" && break
    sleep 5
    echo "  still waiting..."
  done
}

resolve_k3s_version() {
  if [[ "$T_K3S_VERSION" == "latest" ]]; then
    K3S_VERSION=$(curl --silent https://api.github.com/repos/k3s-io/k3s/releases/latest | jq -r '.name')
  else
    K3S_VERSION="$T_K3S_VERSION"
  fi
  echo "Using K3s version: $K3S_VERSION"
}

first_server_name() {
  export OCI_CLI_AUTH=instance_principal
  oci compute instance list \
    --compartment-id "$T_COMPARTMENT_OCID" \
    --availability-domain "$T_AVAILABILITY_DOMAIN" \
    --lifecycle-state RUNNING \
    --sort-by TIMECREATED |
    jq -r '.data[] | select(."display-name" | endswith("k3s-servers")) | .["display-name"]' |
    head -n 1
}

this_server_name() {
  curl -s -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance | jq -r '.displayName'
}

install_longhorn_if_first() {
  if [[ "$T_INSTALL_LONGHORN" == "true" ]]; then
    if [[ "$OS_FAMILY" == "ubuntu" ]]; then
      DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y open-iscsi curl util-linux
    elif [[ "$OS_FAMILY" == "oraclelinux" ]]; then
      dnf -y install iscsi-initiator-utils util-linux || true
    fi
    systemctl enable --now iscsid.service || true
    kubectl apply -f "https://raw.githubusercontent.com/longhorn/longhorn/$T_LONGHORN_RELEASE/deploy/longhorn.yaml"
  fi
}

install_ingress_nginx_nodeport() {
  # Deploy controller (baremetal manifest)
  kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-$T_NGINX_INGRESS_RELEASE/deploy/static/provider/baremetal/deploy.yaml"

  # Create a NodePort service + ConfigMap (no PROXY protocol; trust forwarded headers)
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
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
data:
  allow-snippet-annotations: "true"
  use-forwarded-headers: "true"
  compute-full-forwarded-for: "true"
  enable-real-ip: "true"
  proxy-real-ip-cidr: "0.0.0.0/0"
  proxy-body-size: "20m"
  use-proxy-protocol: "false"
YAML
  kubectl apply -f /root/nginx-ingress-nodeport.yaml
}

# --------------------- Main logic ------------------------
detect_os
base_setup
resolve_k3s_version

# Build server params (use a simple string to avoid ${params[*]})
PARAMS="--tls-san $T_TLS_SAN_PRIV"
if [[ "$T_K3S_SUBNET" != "default_route_table" ]]; then
  local_ip=$(ip -4 route ls "$T_K3S_SUBNET" | grep -Po '(?<=src )(\S+)' || true)
  flannel_iface=$(ip -4 route ls "$T_K3S_SUBNET" | grep -Po '(?<=dev )(\S+)' || true)
  if [[ -n "${local_ip:-}" ]]; then PARAMS="$PARAMS --node-ip $local_ip --advertise-address $local_ip"; fi
  if [[ -n "${flannel_iface:-}" ]]; then PARAMS="$PARAMS --flannel-iface $flannel_iface"; fi
fi
# Disable the default traefik if we will use nginx (or if explicitly disabled)
if [[ "$T_DISABLE_INGRESS" == "true" ]]; then
  PARAMS="$PARAMS --disable traefik"
else
  if [[ "$T_INGRESS_CONTROLLER" != "default" ]]; then
    PARAMS="$PARAMS --disable traefik"
  fi
fi
if [[ "$T_EXPOSE_KUBEAPI" == "true" ]]; then
  PARAMS="$PARAMS --tls-san $T_TLS_SAN_PUB"
fi
if [[ "$OS_FAMILY" == "oraclelinux" ]]; then
  PARAMS="$PARAMS --selinux"
fi

FIRST_NAME=$(first_server_name || true)
THIS_NAME=$(this_server_name || true)

if [[ -n "${FIRST_NAME:-}" && "$FIRST_NAME" == "$THIS_NAME" ]]; then
  echo "This is the FIRST server. Initializing cluster..."
  until (curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" K3S_TOKEN="$T_K3S_TOKEN" sh -s - server --cluster-init $PARAMS); do
    echo "k3s cluster-init failed, retrying..."
    sleep 5
  done
else
  echo "This server is JOINING an existing cluster..."
  # wait for API via private LB
  wait_for_api_lb
  until (curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" K3S_TOKEN="$T_K3S_TOKEN" K3S_URL="$T_K3S_URL" sh -s - server $PARAMS); do
    echo "k3s server join failed, retrying..."
    sleep 5
  done
fi

# Wait for k3s to be usable
echo "Waiting for pods to be Running..."
until kubectl get pods -A | grep -q 'Running'; do
  sleep 5
done

# First-server only post steps
if [[ -n "${FIRST_NAME:-}" && "$FIRST_NAME" == "$THIS_NAME" ]]; then
  install_longhorn_if_first
  if [[ "$T_DISABLE_INGRESS" != "true" && "$T_INGRESS_CONTROLLER" == "nginx" ]]; then
    install_ingress_nginx_nodeport
  fi
fi

echo "K3s server setup complete."
