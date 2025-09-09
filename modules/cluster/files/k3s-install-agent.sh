#!/bin/bash
# K3s AGENT install script with role-aware setup.
# - Application workers join normally.
# - DB worker mounts the extra OCI paravirtualized block volume (no iSCSI/CSI),
#   formats it if needed, and prepares /mnt/oci/db/postgres for a Local PV.
set -euo pipefail
exec > >(tee /var/log/cloud-init-output.log | logger -t user-data -s 2>/dev/console) 2>&1

# --- Vars injected by Terraform (must match modules/cluster/nodes.tf) ---
T_K3S_VERSION="${T_K3S_VERSION}"
T_K3S_TOKEN="${T_K3S_TOKEN}"
T_K3S_URL_IP="${T_K3S_URL_IP}"
T_NODE_LABELS="${T_NODE_LABELS}"
T_NODE_TAINTS="${T_NODE_TAINTS}"

install_base_tools() {
  echo "Installing base packages (jq, e2fsprogs, util-linux, curl)..."
  dnf -y update || true
  dnf -y install jq e2fsprogs util-linux curl || true
}

setup_local_db_volume() {
  # Only on the DB node (role=database)
  echo "$T_NODE_LABELS" | grep -q "role=database" || { echo "Not a DB node; skipping local volume prep."; return 0; }

  echo "Preparing local block volume for DB (paravirtualized attach)..."
  DEV="$(ls /dev/oracleoci/oraclevd[b-z] 2>/dev/null | head -n1 || true)"

  if [ -z "$DEV" ]; then
    echo "⚠️  No extra OCI volume found under /dev/oracleoci; DB will fall back to ephemeral root disk."
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

  # Postgres runs as uid/gid 999 in the chart defaults; ensure ownership.
  mkdir -p /mnt/oci/db/postgres
  chown -R 999:999 /mnt/oci/db
  echo "✅ DB volume ready at /mnt/oci/db (PV path: /mnt/oci/db/postgres)."
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
  setup_local_db_volume
  install_k3s_agent
}

main "$@"
