#!/bin/bash
set -euo pipefail

# Keep wrapper logs separate
exec > /var/log/cloud-init-wrapper.log 2>&1

# --- 1) Write runtime env (interpolated by Terraform) ---
cat > /etc/bootstrap-env <<'ENVEOF'
export T_K3S_VERSION="${T_K3S_VERSION}"
export T_K3S_TOKEN="${T_K3S_TOKEN}"
export T_DB_USER="${T_DB_USER}"
export T_DB_NAME_DEV="${T_DB_NAME_DEV}"
export T_DB_NAME_PROD="${T_DB_NAME_PROD}"
export T_DB_SERVICE_NAME_DEV="${T_DB_SERVICE_NAME_DEV}"
export T_DB_SERVICE_NAME_PROD="${T_DB_SERVICE_NAME_PROD}"
export T_MANIFESTS_REPO_URL="${T_MANIFESTS_REPO_URL}"
export T_EXPECTED_NODE_COUNT="${T_EXPECTED_NODE_COUNT}"
export T_PRIVATE_LB_IP="${T_PRIVATE_LB_IP}"
ENVEOF

chmod 600 /etc/bootstrap-env
echo "Wrote /etc/bootstrap-env"

# --- 2) Decode and install the heavy bootstrap script written as base64 ---
# (bootstrap_b64 comes from Terraform template substitution; it's a single-line base64 string)
base64 -d <<'B64' > /usr/local/bin/bootstrap-newsapp.sh
${bootstrap_b64}
B64

chmod 700 /usr/local/bin/bootstrap-newsapp.sh
chown root:root /usr/local/bin/bootstrap-newsapp.sh
echo "Wrote /usr/local/bin/bootstrap-newsapp.sh"

# --- 3) Create the systemd oneshot service to run the heavy bootstrap asynchronously ---
cat > /etc/systemd/system/bootstrap-newsapp.service <<'UNIT'
[Unit]
Description=Bootstrap newsapp (k3s/ingress/argocd/secrets)
After=network-online.target k3s.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/bootstrap-newsapp.sh
TimeoutStartSec=30min
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now bootstrap-newsapp.service || systemctl start bootstrap-newsapp.service || true

echo "bootstrap-newsapp.service installed and started (or starting). Check: journalctl -u bootstrap-newsapp -f"
