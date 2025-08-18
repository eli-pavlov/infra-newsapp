#!/bin/bash
# K3s AGENT install (joins via PRIVATE LB).
set -euo pipefail

# ------- Vars injected by Terraform -------
T_K3S_VERSION="${k3s_version}"
T_K3S_SUBNET="${k3s_subnet}"
T_K3S_TOKEN="${k3s_token}"
T_K3S_URL="https://${k3s_url}:6443"
T_NODE_NAME="${node_name}" # e.g., node-1, node-2, node-3
T_NODE_ROLE="${node_role}" # "app" or "db"
T_DB_VOLUME_DEVICE="${db_volume_device}"
T_DB_MOUNT_PATH="${db_mount_path}"

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

mount_db_volume_if_needed() {
  if [[ "$T_NODE_ROLE" == "db" ]]; then
    echo "This is a DB node. Setting up block volume mount..."
    DB_DEV="$T_DB_VOLUME_DEVICE"
    DB_MNT="$T_DB_MOUNT_PATH"
    echo "Waiting for DB device $DB_DEV ..."
    for i in {1..120}; do
      [ -b "$DB_DEV" ] && break
      sleep 1
    done
    if [ ! -b "$DB_DEV" ]; then
      echo "::error:: Block device $DB_DEV not found on DB node!"
      exit 1
    fi
    if ! blkid "$DB_DEV" >/dev/null 2>&1; then
      echo "Formatting $DB_DEV as ext4..."
      mkfs.ext4 -F "$DB_DEV"
    fi
    mkdir -p "$DB_MNT"
    UUID=$(blkid -s UUID -o value "$DB_DEV")
    if ! grep -q "$UUID" /etc/fstab; then
      echo "UUID=$UUID $DB_MNT ext4 defaults,nofail 0 2" >> /etc/fstab
    fi
    mount -a
    echo "Block volume mounted at $DB_MNT."
  fi
}

# --------------------- Main logic ------------------------
detect_os
base_setup
mount_db_volume_if_needed

# Build K3s agent install parameters
PARAMS="--node-name $T_NODE_NAME --node-label=node.role=$T_NODE_ROLE"

# Taint the DB node so only DB-specific pods can be scheduled there
if [[ "$T_NODE_ROLE" == "db" ]]; then
  PARAMS="$PARAMS --kubelet-arg=register-with-taints=role=db:NoSchedule"
fi

if [[ "$T_K3S_SUBNET" != "default_route_table" ]]; then
  local_ip=$(ip -4 route ls "$T_K3S_SUBNET" | grep -Po '(?<=src )(\S+)' || true)
  flannel_iface=$(ip -4 route ls "$T_K3S_SUBNET" | grep -Po '(?<=dev )(\S+)' || true)
  if [[ -n "${local_ip:-}" ]]; then PARAMS="$PARAMS --node-ip $local_ip"; fi
  if [[ -n "${flannel_iface:-}" ]]; then PARAMS="$PARAMS --flannel-iface $flannel_iface"; fi
fi
if [[ "$OS_FAMILY" == "oraclelinux" ]]; then PARAMS="$PARAMS --selinux"; fi

resolve_k3s_version
wait_for_api_lb

# Install K3s as an AGENT
echo "Installing K3s agent with params: $PARAMS"
until (curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" K3S_TOKEN="$T_K3S_TOKEN" K3S_URL="$T_K3S_URL" sh -s - agent $PARAMS); do
  echo "k3s agent did not install correctly, retrying..."
  sleep 3
done

echo "K3s agent setup complete for node $T_NODE_NAME."
