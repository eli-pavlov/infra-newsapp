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

# --- Function to handle dnf/rpm lock race conditions with retries ---
run_with_lock_retry() {
    local max_retries=10
    local attempt=0
    local cmd=("$@")

    until [ $attempt -ge $max_retries ]
    do
        "${cmd[@]}" && return 0
        local exit_code=$?
        
        # Check if the failure is due to a lock file
        if [ $exit_code -eq 1 ] && [ -f /var/lib/rpm/.rpm.lock ]; then
            echo "INFO: RPM database locked. Retrying in 10 seconds... (Attempt $((attempt+1))/${max_retries})"
            sleep 10
            attempt=$((attempt+1))
        else
            echo "❌ ERROR: Command failed with exit code $exit_code: ${cmd[*]}"
            exit $exit_code
        fi
    done

    echo "❌ ERROR: Command failed after ${max_retries} attempts: ${cmd[*]}"
    exit 1
}

# --- Function to wait for the K3s server to be ready ---
wait_for_server() {
  local timeout=600 # 10 minutes
  local start_time=$(date +%s)

  echo "INFO: Waiting for K3s server to be available at https://${T_K3S_URL_IP}:6443/ping..."

  while true; do
    # The -k flag is necessary because the server uses a self-signed cert initially.
    # We now use the Terraform variable directly to avoid templating conflicts.
    if curl -k --connect-timeout 5 --silent --output /dev/null "https://${T_K3S_URL_IP}:6443/ping"; then
      echo "✅ K3s server is responsive. Proceeding with agent installation."
      break
    fi

    local elapsed_time=$(( $(date +%s) - start_time ))
    if [ "$elapsed_time" -gt "$timeout" ]; then
      echo "❌ ERROR: Timed out waiting for K3s server after ${timeout}s."
      exit 1
    fi

    echo "($elapsed_time/$timeout s) Server not ready yet, waiting 10 seconds..."
    sleep 10
  done
}

install_base_tools() {
  echo "INFO: Installing base packages (dnf: jq, e2fsprogs, util-linux, curl)..."
  # Refresh metadata then install packages (keeping behaviour minimal/explicit)
  run_with_lock_retry dnf makecache --refresh -y || true
  run_with_lock_retry dnf install -y jq e2fsprogs util-linux curl || true
  echo "✅ Base tools installed."
}

systemctl disable firewalld --now

setup_local_db_volume() {
  # Only on the DB node (role=database)
  echo "$T_NODE_LABELS" | grep -q "role=database" || { echo "INFO: Not a DB node; skipping local volume prep."; return 0; }

  echo "INFO: Preparing local block volume for DB (paravirtualized attach)..."
  # Check for Oracle Linux device naming first
  DEV="$(ls /dev/oracleoci/oraclevd[b-z] 2>/dev/null | head -n1 || true)"
  # Fallback to standard Linux device naming if no Oracle Linux device found
  if [ -z "$DEV" ]; then
    DEV="$(ls /dev/sd[b-z] /dev/nvme*n* 2>/dev/null | head -n1 || true)"
  fi

  if [ -z "$DEV" ]; then
    echo "⚠️  WARNING: No extra OCI volume found; DB will fall back to ephemeral root disk."
    return 0
  fi

  echo "INFO: Detected extra volume: $DEV"
  if ! blkid "$DEV" >/dev/null 2>&1; then
    echo "INFO: No filesystem on $DEV; creating ext4..."
    mkfs.ext4 -F "$DEV"
    if [ $? -ne 0 ]; then
      echo "❌ ERROR: Failed to create ext4 filesystem on $DEV."
      exit 1
    fi
  else
    echo "INFO: Filesystem already present on $DEV; leaving as-is."
  fi

  UUID="$(blkid -s UUID -o value "$DEV")"
  if [ -z "$UUID" ]; then
      echo "❌ ERROR: Failed to get UUID for device $DEV."
      exit 1
  fi

  # Ensure mountpoint exists BEFORE mounting
  mkdir -p /mnt/oci/db

  # Ensure fstab entry exists (mount at boot)
  if ! grep -q "$UUID" /etc/fstab; then
    echo "INFO: Adding fstab entry for UUID=$UUID"
    echo "UUID=$UUID /mnt/oci/db ext4 defaults,noatime 0 2" >> /etc/fstab
  else
    echo "INFO: fstab entry for UUID=$UUID already exists."
  fi

  echo "INFO: Mounting all filesystems from /etc/fstab..."
  mount -a
  if [ $? -ne 0 ]; then
      echo "❌ ERROR: Failed to mount all filesystems. Check fstab and device status."
      exit 1
  fi
  if ! mountpoint -q /mnt/oci/db; then
      echo "❌ ERROR: Mount point /mnt/oci/db is not active after mount -a."
      exit 1
  fi

  # Create dev and prod PV paths; Postgres runs as uid/gid 999 in the chart defaults
  echo "INFO: Creating and setting permissions for PV paths."
  mkdir -p /mnt/oci/db/dev /mnt/oci/db/prod
  chown -R 999:999 /mnt/oci/db/dev /mnt/oci/db/prod
  chmod -R 700 /mnt/oci/db/dev /mnt/oci/db/prod

  # Verify directories exist and have correct ownership
  for path in /mnt/oci/db/dev /mnt/oci/db/prod; do
    if [ ! -d "$path" ]; then
      echo "❌ ERROR: $path does not exist after creation."
      exit 1
    fi
    if [ "$(stat -c %u:%g "$path")" != "999:999" ]; then
      echo "❌ ERROR: $path has incorrect ownership (expected 999:999, got $(stat -c %u:%g "$path"))."
      exit 1
    fi
  done
  echo "✅ PV paths verified."

  # Migrate existing data from /mnt/oci/db/postgres if it exists
  if [ -d /mnt/oci/db/postgres ] && [ "$(ls -A /mnt/oci/db/postgres)" ]; then
    echo "INFO: Found existing data in /mnt/oci/db/postgres; migrating to /mnt/oci/db/dev..."
    cp -r /mnt/oci/db/postgres/. /mnt/oci/db/dev/
    echo "INFO: Data migrated to /mnt/oci/db/dev; removing old /mnt/oci/db/postgres..."
    rm -rf /mnt/oci/db/postgres
  fi

  echo "✅ DB volume ready at /mnt/oci/db (PV paths: /mnt/oci/db/dev, /mnt/oci/db/prod)."
}

install_k3s_agent() {
  echo "INFO: Joining K3s cluster at https://${T_K3S_URL_IP}:6443"
  
  local params="--node-label ${T_NODE_LABELS}"
  if [[ -n "$T_NODE_TAINTS" ]]; then
    params="$params --node-taint ${T_NODE_TAINTS}"
  fi

  export K3S_URL="https://${T_K3S_URL_IP}:6443"
  export K3S_TOKEN="$T_K3S_TOKEN"
  export INSTALL_K3S_VERSION="$T_K3S_VERSION"
  export INSTALL_K3S_EXEC="$params"

  curl -sfL https://get.k3s.io | sh -
  if [ $? -ne 0 ]; then
      echo "❌ ERROR: K3s agent installation failed."
      exit 1
  fi
  echo "✅ K3s agent setup complete with params: $params"
}

main() {
  echo "--- Starting K3s Agent Node Bootstrap Script ---"
  install_base_tools
  wait_for_server
  setup_local_db_volume
  install_k3s_agent
  echo "--- Script finished successfully. Node should now be joining the cluster. ---"
}

main "$@"
