#!/bin/bash
# K3s AGENT install script with role-aware setup.
# - Application workers join normally.
# - DB worker mounts the extra OCI paravirtualized block volume,
#   formats it if needed, and prepares /mnt/oci/db/dev and /mnt/oci/db/prod for Local PVs.

# --- Script Configuration and Error Handling ---

# Set shell options for robust error handling.
# -e: Exit immediately if a command exits with a non-zero status.
# -u: Treat unset variables as an error when substituting.
# -o pipefail: The return value of a pipeline is the status of the last command to exit with a non-zero status.
set -euo pipefail

# Redirect all output to both a log file and the system logger/console for comprehensive logging.
exec > >(tee /var/log/cloud-init-output.log | logger -t user-data -s 2>/dev/console) 2>&1

# --- Vars injected by Terraform ---
# These variables are placeholders dynamically replaced by Terraform during the
# cloud-init rendering process. They provide necessary configuration values for the agent node.
T_K3S_VERSION="${T_K3S_VERSION}"
T_K3S_TOKEN="${T_K3S_TOKEN}"
T_K3S_URL_IP="${T_K3S_URL_IP}"
T_NODE_LABELS="${T_NODE_LABELS}"
T_NODE_TAINTS="${T_NODE_TAINTS}"

# --- Function Definitions ---

# Waits for the K3s server's API to become available before attempting to join the cluster.
wait_for_server() {
  local timeout=900 # 15 minutes
  local start_time=$(date +%s)

  echo "Waiting for K3s server to be available at https://${T_K3S_URL_IP}:6443/ping..."

  while true; do
    # Use curl to ping the K3s server's health check endpoint.
    # The -k flag is necessary because the server uses a self-signed certificate initially.
    if curl -k --connect-timeout 5 --silent --output /dev/null "https://${T_K3S_URL_IP}:6443/ping"; then
      echo "✅ K3s server is responsive. Proceeding with agent installation."
      break
    fi

    # Timeout logic to prevent the script from hanging indefinitely.
    local elapsed_time=$(( $(date +%s) - start_time ))
    if [ "$elapsed_time" -gt "$timeout" ]; then
      echo "❌ Timed out waiting for K3s server."
      exit 1
    fi

    echo "($elapsed_time/$timeout s) Server not ready yet, waiting 10 seconds..."
    sleep 10
  done
}

# Installs essential base packages required for the agent node setup.
install_base_tools() {
  echo "Installing base packages (dnf: jq, e2fsprogs, util-linux, curl)..."
  # Refresh the dnf cache. `|| true` prevents the script from exiting if this fails.
  dnf makecache --refresh -y || true
  # Update all system packages.
  dnf update -y
  # Install necessary tools: jq (JSON parsing), e2fsprogs (for mkfs), util-linux (for blkid), and curl.
  dnf install -y jq e2fsprogs util-linux curl || true
}

# Disable the system firewall, as K3s manages its own networking rules.
systemctl disable firewalld --now

# Prepares a local block volume specifically for database nodes.
setup_local_db_volume() {
  # Only run on DB nodes (preserve TF-templated labels)
  echo "$T_NODE_LABELS" | grep -q "role=database" || { echo "Not a DB node; skipping local volume prep."; DB_STORAGE_LABEL="local"; return 0; }

  echo "Preparing storage for DB node (OCI volume if present, root FS fallback)..."

  # Detect attached block volume (keep your original probes)
  DEV="$(ls /dev/oracleoci/oraclevd[b-z] 2>/dev/null | head -n1 || true)"
  if [ -z "$DEV" ]; then
    DEV="$(ls /dev/sd[b-z] /dev/nvme*n* 2>/dev/null | head -n1 || true)"
  fi

  # Common paths
  MNT="/mnt/oci/db"
  DEV_DIR="${MNT}/dev"
  PROD_DIR="${MNT}/prod"
  LEGACY="${MNT}/postgres"

  if [ -z "$DEV" ]; then
    echo "⚠️ No extra volume found; using root filesystem."
    # Ensure directories on root FS
    mkdir -p "$DEV_DIR" "$PROD_DIR"
    chown -R 999:999 "$DEV_DIR" "$PROD_DIR"
    chmod -R 700 "$DEV_DIR" "$PROD_DIR"

    # Legacy → dev migration (root FS)
    if [ -d "$LEGACY" ] && [ "$(ls -A "$LEGACY" 2>/dev/null)" ]; then
      echo "Migrating legacy data (root) $LEGACY → $DEV_DIR ..."
      cp -a "$LEGACY"/ "$DEV_DIR"/
      mv "$LEGACY" "${LEGACY}.bak.$(date +%s)"
      echo "Legacy migration (root) complete."
    fi

    DB_STORAGE_LABEL="local"
    echo "✅ DB paths ready on root FS at $MNT"
    return 0
  fi

  echo "Detected extra volume: $DEV"

  # Create filesystem if missing
  if ! blkid "$DEV" >/dev/null 2>&1; then
    echo "No filesystem on $DEV; creating ext4..."
    mkfs.ext4 -F "$DEV"
  else
    echo "Filesystem already present on $DEV; leaving as-is."
  fi

  # --- Pre-mount migration from root → disk (to avoid hiding root data) ---
  ROOT_DEV_DIR="$DEV_DIR"
  ROOT_PROD_DIR="$PROD_DIR"
  mkdir -p /mnt/oci.tmp
  mount "$DEV" /mnt/oci.tmp

  # Prepare target dirs on the disk (temporary mount)
  mkdir -p /mnt/oci.tmp/dev /mnt/oci.tmp/prod
  chown -R 999:999 /mnt/oci.tmp/dev /mnt/oci.tmp/prod
  chmod -R 700 /mnt/oci.tmp/dev /mnt/oci.tmp/prod

  # Migrate root/dev → disk/dev (if any data exists)
  if [ -d "$ROOT_DEV_DIR" ] && [ "$(ls -A "$ROOT_DEV_DIR" 2>/dev/null)" ]; then
    echo "Migrating existing root data $ROOT_DEV_DIR → /mnt/oci.tmp/dev ..."
    cp -a "$ROOT_DEV_DIR"/ /mnt/oci.tmp/dev/
    mv "$ROOT_DEV_DIR" "${ROOT_DEV_DIR}.migrated.$(date +%s)"
  fi

  # Migrate root/prod → disk/prod (if any data exists)
  if [ -d "$ROOT_PROD_DIR" ] && [ "$(ls -A "$ROOT_PROD_DIR" 2>/dev/null)" ]; then
    echo "Migrating existing root data $ROOT_PROD_DIR → /mnt/oci.tmp/prod ..."
    cp -a "$ROOT_PROD_DIR"/ /mnt/oci.tmp/prod/
    mv "$ROOT_PROD_DIR" "${ROOT_PROD_DIR}.migrated.$(date +%s)"
  fi

  # Migrate legacy layout (postgres/) → disk/dev
  if [ -d "$LEGACY" ] && [ "$(ls -A "$LEGACY" 2>/dev/null)" ]; then
    echo "Migrating legacy $LEGACY → /mnt/oci.tmp/dev ..."
    cp -a "$LEGACY"/ /mnt/oci.tmp/dev/
    mv "$LEGACY" "${LEGACY}.bak.$(date +%s)"
  fi

  umount /mnt/oci.tmp
  rmdir /mnt/oci.tmp

  # Stable mount via UUID at /mnt/oci/db (keep your original mountpoint/options)
  UUID="$(blkid -s UUID -o value "$DEV")"
  mkdir -p "$MNT"
  if ! grep -q "$UUID" /etc/fstab; then
    echo "UUID=$UUID $MNT ext4 defaults,noatime 0 2" >> /etc/fstab
  fi

  echo "Mounting all filesystems from /etc/fstab..."
  mount -a

  # Ensure final dirs & permissions (in case of fresh disk)
  mkdir -p "$DEV_DIR" "$PROD_DIR"
  chown -R 999:999 "$DEV_DIR" "$PROD_DIR"
  chmod -R 700 "$DEV_DIR" "$PROD_DIR"

  DB_STORAGE_LABEL="oci"
  echo "✅ DB volume ready at $MNT (PV paths: $DEV_DIR, $PROD_DIR)."
}

# Installs the K3s agent and joins it to the cluster.
install_k3s_agent() {
  echo "Joining K3s cluster at https://${T_K3S_URL_IP}:6443"

  # Build the installation parameters, including node labels and taints from Terraform.
  local params="--node-label ${T_NODE_LABELS}"
  if [[ -n "$T_NODE_TAINTS" ]]; then
    params="$params --node-taint ${T_NODE_TAINTS}"
  fi

  # Set environment variables that the K3s installation script uses.
  export K3S_URL="https://${T_K3S_URL_IP}:6443"
  export K3S_TOKEN="$T_K3S_TOKEN"
  export INSTALL_K3S_VERSION="$T_K3S_VERSION"
  export INSTALL_K3S_EXEC="$params"

  # Download and execute the official K3s installation script.
  curl -sfL https://get.k3s.io | sh -
  echo "✅ K3s agent setup complete with params: $params"
  # Ensure availability of kube config
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  # or copy it for convenience (ensure ownership/permissions afterward)
  sudo cp /etc/rancher/k3s/k3s.yaml $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
}

# --- Main Execution Logic ---
# The main function orchestrates the execution of all setup steps in the correct order.
main() {
  install_base_tools
  wait_for_server
  setup_local_db_volume
  T_NODE_LABELS="${T_NODE_LABELS},dbstorage=${DB_STORAGE_LABEL:-local}"
  install_k3s_agent
}

# Execute the main function, passing any script arguments to it.
main "$@"
