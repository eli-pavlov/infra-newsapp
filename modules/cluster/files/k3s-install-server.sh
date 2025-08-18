#!/bin/bash
set -e

#
# Helper Functions
#

verify_os() {
  # Source the os-release file and verify the OS is Ubuntu
  if [ -f /etc/os-release ]; then
    . /etc/os-release
  else
    echo "!!! Cannot find /etc/os-release" >&2
    exit 1
  fi

  if [[ "$NAME" != "Ubuntu" ]]; then
    echo "!!! This script is designed for Ubuntu only. Detected OS: $NAME" >&2
    exit 1
  fi

  echo "---> Verified OS: Ubuntu"
}

wait_lb() {
  echo "---> Waiting for the load balancer at https://${k3s_url}:6443 to be available..."
  while true; do
    if curl --output /dev/null --silent -k "https://${k3s_url}:6443"; then
      echo "---> Load balancer is responsive. Proceeding."
      break
    fi
    sleep 5
    echo "     Still waiting for LB..."
  done
}

install_helm() {
  echo "---> Installing Helm..."
  curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
  chmod +x get_helm.sh
  ./get_helm.sh
  echo "---> Helm installation complete."
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
    app.kubernetes.io/version: 1.1.1
    helm.sh/chart: ingress-nginx-4.0.16
  name: ingress-nginx-controller
  namespace: ingress-nginx
EOF
}

install_and_configure_nginx(){
  echo "---> Installing and configuring NGINX Ingress Controller..."
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-${nginx_ingress_release}/deploy/static/provider/baremetal/deploy.yaml
  NGINX_RESOURCES_FILE=/root/nginx-ingress-resources.yaml
  render_nginx_config
  kubectl apply -f $NGINX_RESOURCES_FILE
  echo "---> NGINX Ingress Controller installation complete."
}

install_ingress(){
  local INGRESS_CONTROLLER=$1
  if [[ "$INGRESS_CONTROLLER" == "nginx" ]]; then
    install_and_configure_nginx
  else
    echo "!!! Ingress controller '$INGRESS_CONTROLLER' not supported."
  fi
}

#
# Main Execution Logic
#

verify_os

# --- Ubuntu Specific Configuration ---
echo "---> Configuring Ubuntu..."
# Disable firewall
/usr/sbin/netfilter-persistent stop
/usr/sbin/netfilter-persistent flush
systemctl stop netfilter-persistent.service
systemctl disable netfilter-persistent.service

# Install packages
apt-get update
apt-get install -y software-properties-common jq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y python3 python3-pip
pip install oci-cli

# Fix /var/log/journal dir size
echo "SystemMaxUse=100M" >> /etc/systemd/journald.conf
echo "SystemMaxFileSize=100M" >> /etc/systemd/journald.conf
systemctl restart systemd-journald

# --- K3s Installation Logic ---
export OCI_CLI_AUTH=instance_principal
first_instance=$(oci compute instance list --compartment-id ${compartment_ocid} --availability-domain ${availability_domain} --lifecycle-state RUNNING --sort-by TIMECREATED | jq -r '.data[]|select(."display-name" | endswith("k3s-servers")) | .["display-name"]' | tail -n 1)
instance_id=$(curl -s -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance | jq -r '.displayName')

# Build K3s installation parameters
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

# Correctly join array elements into a single string
INSTALL_PARAMS="${k3s_install_params[*]}"

# Determine K3s version
%{ if k3s_version == "latest" }
K3S_VERSION=$(curl --silent https://api.github.com/repos/k3s-io/k3s/releases/latest | jq -r '.name')
%{ else }
K3S_VERSION="${k3s_version}"
%{ endif }
echo "---> Installing K3s Version: $K3S_VERSION"

# --- Run K3s Installer (Cluster Init or Join) ---
if [[ "$first_instance" == "$instance_id" ]]; then
  echo "---> This is the FIRST SERVER. Initializing K3s cluster..."
  until (curl -sfL https://get.k3s.io | ... sh -s - --cluster-init $INSTALL_PARAMS); do
    echo "!!! k3s cluster-init failed, retrying in 5 seconds..."
    sleep 5
  done
else
  echo "---> This is a JOINING SERVER. Waiting for cluster to be ready..."
  wait_lb
  until (curl -sfL https://get.k3s.io | ... sh -s - --server https://... $INSTALL_PARAMS); do
    echo "!!! k3s server join failed, retrying in 5 seconds..."
    sleep 5
  done
fi

# --- Post-Installation Tasks (Run only on servers) ---
%{ if is_k3s_server }
echo "---> Waiting for K3s pods to be in 'Running' state..."
until kubectl get pods -A | grep 'Running'; do
  echo "     Still waiting for k3s startup..."
  sleep 5
done
echo "---> K3s is up and running."

# --- First Server Tasks: Install Helm, Longhorn, and Ingress ---
if [[ "$first_instance" == "$instance_id" ]]; then
  echo "---> Performing post-install tasks on the first server..."

  # Install Helm CLI
  install_helm

  %{ if install_longhorn }
  echo "---> Installing Longhorn storage..."
  DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y open-iscsi curl util-linux
  systemctl enable --now iscsid.service
  kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/${longhorn_release}/deploy/longhorn.yaml
  echo "---> Longhorn installation initiated."
  %{ endif }

  %{ if ! disable_ingress }
  %{ if ingress_controller != "default" }
    install_ingress ${ingress_controller}
  %{ endif }
  %{ endif }
fi
%{ endif }

echo "---> Node configuration complete! ✨"