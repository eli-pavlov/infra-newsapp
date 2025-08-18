#!/bin/bash
# K3s AGENT install (joins via PRIVATE LB). ASCII-only; Terraform only fills the top vars.
set -euo pipefail

# ------- Vars injected by Terraform (strings only) -------
T_K3S_VERSION="${k3s_version}"                # e.g. "latest" or "v1.29.5+k3s1"
T_K3S_SUBNET="${k3s_subnet}"                  # e.g. "default_route_table" or a CIDR selector
T_K3S_TOKEN="${k3s_token}"
T_K3S_URL="https://${k3s_url}:6443"           # Private LB IP for server API
T_INSTALL_LONGHORN="${install_longhorn}"      # "true" or "false"

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
  echo "Agent install on: $OS_FAMILY $OS_MAJOR.$OS_MINOR"
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

install_longhorn_bits_if_needed() {
  if [[ "$T_INSTALL_LONGHORN" == "true" ]]; then
    if [[ "$OS_FAMILY" == "ubuntu" ]]; then
      DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y open-iscsi curl util-linux
      systemctl enable --now iscsid.service || true
    elif [[ "$OS_FAMILY" == "oraclelinux" ]]; then
      dnf -y install iscsi-initiator-utils util-linux || true
      systemctl enable --now iscsid.service || true
    fi
  fi
}

# --------------------- Main logic ------------------------
detect_os
base_setup

# Build K3s install params (use a simple string to avoid ${params[*]})
PARAMS=""
if [[ "$T_K3S_SUBNET" != "default_route_table" ]]; then
  local_ip=$(ip -4 route ls "$T_K3S_SUBNET" | grep -Po '(?<=src )(\S+)' || true)
  flannel_iface=$(ip -4 route ls "$T_K3S_SUBNET" | grep -Po '(?<=dev )(\S+)' || true)
  if [[ -n "${local_ip:-}" ]]; then PARAMS="$PARAMS --node-ip $local_ip"; fi
  if [[ -n "${flannel_iface:-}" ]]; then PARAMS="$PARAMS --flannel-iface $flannel_iface"; fi
fi
if [[ "$OS_FAMILY" == "oraclelinux" ]]; then PARAMS="$PARAMS --selinux"; fi

resolve_k3s_version
wait_for_api_lb

# Install K3s as AGENT (explicit)
until (curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" K3S_TOKEN="$T_K3S_TOKEN" K3S_URL="$T_K3S_URL" sh -s - agent $PARAMS); do
  echo "k3s agent did not install correctly, retrying..."
  sleep 3
done

install_longhorn_bits_if_needed

# Best-effort info
kubectl get nodes -o wide || true
echo "K3s agent setup complete."
