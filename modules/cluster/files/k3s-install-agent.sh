#!/bin/bash
# K3s AGENT install script with roles.
set -euo pipefail
exec > >(tee /var/log/cloud-init-output.log|logger -t user-data -s 2>/dev/console) 2>&1

# --- Vars injected by Terraform ---
T_K3S_VERSION="${k3s_version}"
T_K3S_TOKEN="${k3s_token}"
T_K3S_URL_IP="${k3s_url_ip}"
T_NODE_LABELS="${node_labels}" # e.g., "role=application"
T_NODE_TAINTS="${node_taints}" # e.g., "role=database:NoSchedule"

# --- Main Logic ---
echo "Joining K3s cluster at https://${T_K3S_URL_IP}:6443"

PARAMS="--node-label ${T_NODE_LABELS}"
if [[ -n "$T_NODE_TAINTS" ]]; then
    PARAMS="$PARAMS --node-taint ${T_NODE_TAINTS}"
fi

export K3S_URL="https://${T_K3S_URL_IP}:6443"
export K3S_TOKEN="$T_K3S_TOKEN"
export INSTALL_K3S_VERSION="$T_K3S_VERSION"
export INSTALL_K3S_EXEC="$PARAMS"

# Wait for the ISCSI tools to be available before k3s starts, for block volume mounting
dnf install -y iscsi-initiator-utils
systemctl enable --now iscsid

curl -sfL https://get.k3s.io | sh -

echo "✅ K3s agent setup complete with params: $PARAMS"