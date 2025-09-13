#!/bin/bash
# RKE2 AGENT install script with role-aware setup.
# This script has been escaped to be compatible with Terraform's templatefile function.
set -euo pipefail
exec > >(tee /var/log/cloud-init-output.log | logger -t user-data -s 2>/dev/console) 2>&1

# --- Vars injected by Terraform ---
T_RKE2_VERSION="${T_RKE2_VERSION}"
T_RKE2_TOKEN="${T_RKE2_TOKEN}"
T_RKE2_URL_IP="${T_RKE2_URL_IP}"
T_RKE2_PORT="${T_RKE2_PORT}"
T_NODE_LABELS="${T_NODE_LABELS}"
T_NODE_TAINTS="${T_NODE_TAINTS}"

# Use a runtime variable for the registration port (shell-only usage below).
RKE2_REG_PORT="$${T_RKE2_PORT}"

wait_for_server() {
  local timeout=900 # 15 minutes
  local start_time=$$(date +%s)

  echo "Waiting for RKE2 registration endpoint at https://$${T_RKE2_URL_IP}:$${RKE2_REG_PORT}/ping..."

  while true; do
    if curl -k --connect-timeout 5 --silent --output /dev/null "https://$${T_RKE2_URL_IP}:$${RKE2_REG_PORT}/ping"; then
      echo "✅ RKE2 server registration endpoint is responsive. Proceeding with agent installation."
      break
    fi

    local elapsed_time=$$(( $$(date +%s) - start_time ))
    if [ "$${elapsed_time}" -gt "$${timeout}" ]; then
      echo "❌ Timed out waiting for RKE2 registration endpoint ($${elapsed_time}s)."
      exit 1
    fi

    echo "($${elapsed_time}/$${timeout}s) Server not ready yet, waiting 10 seconds..."
    sleep 10
  done
}

install_base_tools() {
  echo "Installing base packages (dnf: jq, e2fsprogs, util-linux, curl)..."
  dnf makecache --refresh -y || true
  dnf update -y
  dnf install -y jq e2fsprogs util-linux curl || true
}

systemctl disable firewalld --now || true

setup_local_db_volume() {
  echo "$${T_NODE_LABELS}" | grep -q "role=database" || { echo "Not a DB node; skipping local volume prep."; return 0; }

  echo "Preparing local block volume for DB (paravirtualized attach)..."
  DEV=$$(ls /dev/oracleoci/oraclevd[b-z] 2>/dev/null | head -n1 || true)
  if [ -z "$$DEV" ]; then
    DEV=$$(ls /dev/sd[b-z] /dev/nvme*n* 2>/dev/null | head -n1 || true)
  fi

  if [ -z "$$DEV" ]; then
    echo "⚠️  No extra OCI volume found; DB will fall back to ephemeral root disk."
    return 0
  fi

  echo "Detected extra volume: $$DEV"
  if ! blkid "$$DEV" >/dev/null 2>&1; then
    echo "No filesystem on $$DEV; creating ext4..."
    mkfs.ext4 -F "$$DEV"
  else
    echo "Filesystem already present on $$DEV; leaving as-is."
  fi

  UUID=$$(blkid -s UUID -o value "$$DEV")

  mkdir -p /mnt/oci/db
  if ! grep -q "$$UUID" /etc/fstab; then
    echo "UUID=$$UUID /mnt/oci/db ext4 defaults,noatime 0 2" >> /etc/fstab
  fi
  mount -a

  mkdir -p /mnt/oci/db/dev /mnt/oci/db/prod
  chown -R 999:999 /mnt/oci/db/dev /mnt/oci/db/prod
  chmod -R 700 /mnt/oci/db/dev /mnt/oci/db/prod

  for path in /mnt/oci/db/dev /mnt/oci/db/prod; do
    if [ ! -d "$$path" ]; then
      echo "Error: $$path does not exist"
      exit 1
    fi
    if [ "$$(stat -c %u:%g "$$path")" != "999:999" ]; then
      echo "Error: $$path has incorrect ownership (expected 999:999)"
      exit 1
    fi
  done

  if [ -d /mnt/oci/db/postgres ] && [ "$$(ls -A /mnt/oci/db/postgres)" ]; then
    echo "Found existing data in /mnt/oci/db/postgres; migrating to /mnt/oci/db/dev..."
    cp -r /mnt/oci/db/postgres/. /mnt/oci/db/dev/
    rm -rf /mnt/oci/db/postgres
  fi

  echo "✅ DB volume ready at /mnt/oci/db (PV paths: /mnt/oci/db/dev, /mnt/oci/db/prod)."
}

install_rke2_agent() {
  echo "Joining RKE2 cluster at https://$${T_RKE2_URL_IP}:$${RKE2_REG_PORT} (registration) and K8s API at :6443"

  mkdir -p /etc/rancher/rke2
  chmod 700 /etc/rancher/rke2

  cat > /etc/rancher/rke2/config.yaml <<EOF
server: "https://$${T_RKE2_URL_IP}:$${RKE2_REG_PORT}"
token: "${T_RKE2_TOKEN}"
EOF

  if [ -n "${T_NODE_LABELS}" ]; then
    echo "node-label:" >> /etc/rancher/rke2/config.yaml
    for lb in $${T_NODE_LABELS}; do
      echo "  - \"$$lb\"" >> /etc/rancher/rke2/config.yaml
    done
  fi

  if [ -n "${T_NODE_TAINTS}" ]; then
    echo "node-taint:" >> /etc/rancher/rke2/config.yaml
    for tt in $${T_NODE_TAINTS}; do
      echo "  - \"$$tt\"" >> /etc/rancher/rke2/config.yaml
    done
  fi

  export INSTALL_RKE2_VERSION="${T_RKE2_VERSION}"
  export INSTALL_RKE2_TYPE="agent"

  local ver="$${INSTALL_RKE2_VERSION}"
  if [ -z "$$ver" ]; then
    ver="latest"
  fi

  echo "Running RKE2 agent installer (version: $$ver)..."
  curl -sfL https://get.rke2.io | sh -

  systemctl enable --now rke2-agent.service

  echo "✅ RKE2 agent setup complete. Agent service enabled and started."
}

main() {
  install_base_tools
  wait_for_server
  setup_local_db_volume
  install_rke2_agent
}

main "$@"
