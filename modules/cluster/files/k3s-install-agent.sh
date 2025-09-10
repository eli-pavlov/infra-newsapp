#!/bin/bash
# K3s AGENT install script with role-aware setup.
# - Application workers join normally.
# - DB worker mounts the extra OCI paravirtualized block volume (no iSCSI/CSI),
#   formats it if needed, and prepares /mnt/oci/db/dev and /mnt/oci/db/prod for Local PVs.
set -euo pipefail
exec > >(tee /var/log/cloud-init-output.log | logger -t user-data -s 2>/dev/console) 2>&1

# --- Vars injected by Terraform (must match modules/cluster/nodes.tf) ---
T_K3S_VERSION="${T_K3S_VERSION}"
T_K3S_TOKEN="${T_K3S_TOKEN}"
T_K3S_URL_IP="${T_K3S_URL_IP}"
T_NODE_LABELS="${T_NODE_LABELS}"
T_NODE_TAINTS="${T_NODE_TAINTS}"

# --- Function to wait for the K3s server to be ready ---
wait_for_server() {
  local timeout=600 # 10 minutes
  local start_time=$(date +%s)

  echo "Waiting for K3s server to be available at https://${T_K3S_URL_IP}:6443/ping..."

  while true; do
    # The -k flag is necessary because the server uses a self-signed cert initially.
    # This now uses the Terraform variable directly to avoid templating conflicts.
    if curl -k --connect-timeout 5 --silent --output /dev/null "https://${T_K3S_URL_IP}:6443/ping"; then
      echo "✅ K3s server is responsive. Proceeding with agent installation."
      break
    fi

    local elapsed_time=$(( $(date +%s) - start_time ))
    if [ "$elapsed_time" -gt "$timeout" ]; then
      echo "❌ Timed out waiting for K3s server."
      exit 1
    fi

    echo "($elapsed_time/$timeout s) Server not ready yet, waiting 10 seconds..."
    sleep 10
  done
}

install_base_tools() {
  echo "Installing base packages (jq, e2fsprogs, util-linux, curl)..."
  apt-get update -y || true
  apt-get install -y jq e2fsprogs util-linux curl || true
}

disable_firewalls() {
  echo "Flushing and disabling firewalls (iptables and nftables)..."
  # Flush iptables
  if command -v iptables >/dev/null; then
    sudo iptables -F
    sudo iptables -X
    sudo iptables -P INPUT ACCEPT
    sudo iptables -P FORWARD ACCEPT
    sudo iptables -P OUTPUT ACCEPT
    echo "✅ iptables rules flushed and policies set to ACCEPT."
  else
    echo "iptables not installed."
  fi
  # Flush nftables
  if command -v nft >/dev/null; then
    sudo nft flush ruleset
    echo "✅ nftables rules flushed."
  else
    echo "nftables not installed."
  fi
  # Disable services
  if systemctl is-active --quiet nftables; then
    sudo systemctl stop nftables
    sudo systemctl disable nftables
    echo "✅ nftables service stopped and disabled."
  else
    echo "nftables service not active."
  fi
  if systemctl is-active --quiet ufw; then
    sudo ufw disable
    echo "✅ ufw disabled."
  else
    echo "ufw not active."
  fi
  # Stop netfilter-persistent if present
  if systemctl is-active --quiet netfilter-persistent; then
    sudo systemctl stop netfilter-persistent
    sudo systemctl disable netfilter-persistent
    echo "✅ netfilter-persistent stopped and disabled."
  else
    echo "netfilter-persistent not active."
  fi
}

setup_local_db_volume() {
  # Only on the DB node (role=database)
  echo "$T_NODE_LABELS" | grep -q "role=database" || { echo "Not a DB node; skipping local volume prep."; return 0; }

  echo "Preparing local block volume for DB (paravirtualized attach)..."
  # Check for Oracle Linux device naming first
  DEV="$(ls /dev/oracleoci/oraclevd[b-z] 2>/dev/null | head -n1 || true)"
  # Fallback to standard Linux device naming if no Oracle Linux device found
  if [ -z "$DEV" ]; then
    DEV="$(ls /dev/sd[b-z] /dev/nvme*n* 2>/dev/null | head -n1 || true)"
  fi
  
  if [ -z "$DEV" ]; then
    echo "⚠️  No extra OCI volume found; DB will fall back to ephemeral root disk."
    return 0
  fi

  echo "Detected extra volume: $DEV"
  if ! blkid "$DEV" >/dev/null 2>&1; then
    echo "No filesystem on $DEV; creating ext4..."
    mkfs.ext4 -F "$DEV"
  else
    echo "Filesystem already present on $DEV; leaving as-is."
  fi

  UUID="$(blkid -s UUID -o value "$DEV")"

  # Ensure mountpoint exists BEFORE mounting
  mkdir -p /mnt/oci/db

  # Ensure fstab entry exists (mount at boot)
  if ! grep -q "$UUID" /etc/fstab; then
    echo "UUID=$UUID /mnt/oci/db ext4 defaults,noatime 0 2" >> /etc/fstab
  fi

  echo "Mounting all filesystems from /etc/fstab..."
  mount -a

  # Create dev and prod PV paths; Postgres runs as uid/gid 999 in the chart defaults
  mkdir -p /mnt/oci/db/dev /mnt/oci/db/prod
  chown -R 999:999 /mnt/oci/db/dev /mnt/oci/db/prod
  chmod -R 700 /mnt/oci/db/dev /mnt/oci/db/prod

  # Verify directories exist and have correct ownership
  for path in /mnt/oci/db/dev /mnt/oci/db/prod; do
    if [ ! -d "$path" ]; then
      echo "Error: $path does not exist"
      exit 1
    fi
    if [ "$(stat -c %u:%g "$path")" != "999:999" ]; then
      echo "Error: $path has incorrect ownership (expected 999:999)"
      exit 1
    fi
  done

  # Migrate existing data from /mnt/oci/db/postgres if it exists
  if [ -d /mnt/oci/db/postgres ] && [ "$(ls -A /mnt/oci/db/postgres)" ]; then
    echo "Found existing data in /mnt/oci/db/postgres; migrating to /mnt/oci/db/dev..."
    cp -r /mnt/oci/db/postgres/. /mnt/oci/db/dev/
    echo "Data migrated to /mnt/oci/db/dev; removing old /mnt/oci/db/postgres..."
    rm -rf /mnt/oci/db/postgres
  fi

  echo "✅ DB volume ready at /mnt/oci/db (PV paths: /mnt/oci/db/dev, /mnt/oci/db/prod)."
}

install_k3s_agent() {
  echo "Joining K3s cluster at https://${T_K3S_URL_IP}:6443"

  local params="--node-label ${T_NODE_LABELS}"
  if [[ -n "$T_NODE_TAINTS" ]]; then
    params="$params --node-taint ${T_NODE_TAINTS}"
  fi

  export K3S_URL="https://${T_K3S_URL_IP}:6443"
  export K3S_TOKEN="$T_K3S_TOKEN"
  export INSTALL_K3S_VERSION="$T_K3S_VERSION"
  export INSTALL_K3S_EXEC="$params"

  curl -sfL https://get.k3s.io | sh -
  echo "✅ K3s agent setup complete with params: $params"
}

main() {
  install_base_tools
  disable_firewalls
  wait_for_server
  setup_local_db_volume
  install_k3s_agent
}

main "$@"

