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
  # This function only runs if the node has the label "role=database".
  echo "$T_NODE_LABELS" | grep -q "role=database" || { echo "Not a DB node; skipping local volume prep."; return 0; }

  echo "Preparing local block volume for DB (paravirtualized attach)..."
  # Detect the attached block volume device, checking for Oracle-specific paths first.
  DEV="$(ls /dev/oracleoci/oraclevd[b-z] 2>/dev/null | head -n1 || true)"
  # Fallback to standard Linux device naming if the Oracle path is not found.
  if [ -z "$DEV" ]; then
    DEV="$(ls /dev/sd[b-z] /dev/nvme*n* 2>/dev/null | head -n1 || true)"
  fi
  
  if [ -z "$DEV" ]; then
    echo "⚠️ No extra OCI volume found; DB will fall back to ephemeral root disk."
    return 0
  fi

  echo "Detected extra volume: $DEV"
  # Check if the volume already has a filesystem. If not, format it with ext4.
  if ! blkid "$DEV" >/dev/null 2>&1; then
    echo "No filesystem on $DEV; creating ext4..."
    mkfs.ext4 -F "$DEV"
  else
    echo "Filesystem already present on $DEV; leaving as-is."
  fi

  # Get the UUID of the device for a stable fstab entry.
  UUID="$(blkid -s UUID -o value "$DEV")"

  # Ensure the mount point exists.
  mkdir -p /mnt/oci/db

  # Add an entry to /etc/fstab to ensure the volume is mounted on boot.
  if ! grep -q "$UUID" /etc/fstab; then
    echo "UUID=$UUID /mnt/oci/db ext4 defaults,noatime 0 2" >> /etc/fstab
  fi

  echo "Mounting all filesystems from /etc/fstab..."
  mount -a

  # Create subdirectories for development and production persistent volumes.
  # Set ownership to 999:999, which is the default user/group for the PostgreSQL Helm chart.
  mkdir -p /mnt/oci/db/dev /mnt/oci/db/prod
  chown -R 999:999 /mnt/oci/db/dev /mnt/oci/db/prod
  chmod -R 700 /mnt/oci/db/dev /mnt/oci/db/prod

  # Verify that the directories were created with the correct ownership.
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

  # Simple data migration logic for backward compatibility.
  if [ -d /mnt/oci/db/postgres ] && [ "$(ls -A /mnt/oci/db/postgres)" ]; then
    echo "Found existing data in /mnt/oci/db/postgres; migrating to /mnt/oci/db/dev..."
    cp -r /mnt/oci/db/postgres/. /mnt/oci/db/dev/
    echo "Data migrated to /mnt/oci/db/dev; removing old /mnt/oci/db/postgres..."
    rm -rf /mnt/oci/db/postgres
  fi

  echo "✅ DB volume ready at /mnt/oci/db (PV paths: /mnt/oci/db/dev, /mnt/oci/db/prod)."
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
  install_k3s_agent
}

# Execute the main function, passing any script arguments to it.
main "$@"
