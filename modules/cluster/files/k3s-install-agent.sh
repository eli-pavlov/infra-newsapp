#!/bin/bash
# ASCII-only; cleaned. Installs K3s agent and joins to server via LB.
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

  echo "K3s agent install:"
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
    apt-get install -y software-properties-common jq curl openssl
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y python3 python3-pip
  elif [[ "$operating_system" == "oraclelinux" ]]; then
    systemctl disable --now firewalld || true
    echo '(allow iptables_t cgroup_t (dir (ioctl)))' > /root/local_iptables.cil
    semodule -i /root/local_iptables.cil || true
    dnf -y update
    if [[ $major -eq 9 ]]; then
      dnf -y install oraclelinux-developer-release-el9
      dnf -y install jq curl openssl python39-oci-cli
    else
      dnf -y install oraclelinux-developer-release-el8
      dnf -y module enable python36:3.6
      dnf -y install jq curl openssl python36-oci-cli
    fi
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

# Main
check_os
install_base_packages

k3s_install_params=()

%{ if k3s_subnet != "default_route_table" }
local_ip=$(ip -4 route ls ${k3s_subnet} | grep -Po '(?<=src )(\S+)')
flannel_iface=$(ip -4 route ls ${k3s_subnet} | grep -Po '(?<=dev )(\S+)')
k3s_install_params+=("--node-ip $local_ip")
k3s_install_params+=("--advertise-address $local_ip")
k3s_install_params+=("--flannel-iface $flannel_iface")
%{ endif }

%{ if disable_ingress }
k3s_install_params+=("--disable traefik")
%{ else }
%{ if ingress_controller != "default" }
k3s_install_params+=("--disable traefik")
%{ endif }
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

wait_lb
until (curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" K3S_TOKEN=${k3s_token} K3S_URL=https://${k3s_url}:6443 sh -s - agent $INSTALL_PARAMS); do
  echo "k3s agent did not install correctly"
  sleep 2
done

# Best-effort readiness output
kubectl get nodes -o wide || true
