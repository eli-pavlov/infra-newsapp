#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/cloud-init-output.log | logger -t user-data -s 2>/dev/console) 2>&1

# --- Vars injected by Terraform ---
T_K3S_VERSION="${T_K3S_VERSION:-}"
T_K3S_TOKEN="${T_K3S_TOKEN:-}"
T_K3S_SERVER="${T_K3S_SERVER:-}"   # e.g. "https://10.0.2.118:6443" or "10.0.2.118"
T_WAIT_SERVER_SECONDS="${T_WAIT_SERVER_SECONDS:-600}"  # how long to wait for server TCP
T_WAIT_JOIN_SECONDS="${T_WAIT_JOIN_SECONDS:-300}"     # how long to wait for agent join
# optional node role/labels
T_NODE_LABELS="${T_NODE_LABELS:-}"  # e.g. "role=application,env=dev"
T_NODE_SELECTOR="${T_NODE_SELECTOR:-}" # use if you want to influence helm installs

log() { echo "[$(date -Is)] $*"; }

install_base_tools() {
  log "Installing base packages (dnf)..."
  dnf makecache --refresh -y || true
  dnf install -y curl jq netcat-openbsd || true
}

disable_firewall() {
  if systemctl is-enabled --quiet firewalld; then
    log "Disabling firewalld"
    systemctl disable --now firewalld || true
  fi
}

get_private_ip() {
  log "Fetching instance private IP from metadata (OCI metadata endpoint)..."
  PRIVATE_IP=$(curl -s -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/vnics/ | jq -r '.[0].privateIp' 2>/dev/null || true)
  if [ -z "${PRIVATE_IP:-}" ] || [ "${PRIVATE_IP}" = "null" ]; then
    log "❌ Failed to fetch private IP from metadata; falling back to ip route check"
    PRIVATE_IP=$(ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 || true)
  fi
  if [ -z "${PRIVATE_IP:-}" ]; then
    log "❌ Could not determine private IP. Exiting."
    exit 1
  fi
  log "✅ Instance private IP is ${PRIVATE_IP}"
}

wait_for_server_api_tcp() {
  # Accept T_K3S_SERVER in several forms: "https://ip:6443", "ip", or "ip:6443"
  if [ -z "${T_K3S_SERVER}" ]; then
    log "T_K3S_SERVER not provided - cannot continue."
    exit 1
  fi

  # Normalise host:port
  SERVER_HOST="${T_K3S_SERVER#https://}"
  SERVER_HOST="${SERVER_HOST#http://}"
  SERVER_HOST="${SERVER_HOST%%/*}"   # remove any trailing path
  if [[ "$SERVER_HOST" != *:* ]]; then
    SERVER_HOST="${SERVER_HOST}:6443"
  fi
  SERVER_IP="${SERVER_HOST%%:*}"
  SERVER_PORT="${SERVER_HOST##*:}"

  log "Waiting up to ${T_WAIT_SERVER_SECONDS}s for control-plane TCP ${SERVER_IP}:${SERVER_PORT}..."

  local start now
  start=$(date +%s)
  while true; do
    if nc -z -w 3 "$SERVER_IP" "$SERVER_PORT"; then
      log "✅ Control-plane TCP ${SERVER_IP}:${SERVER_PORT} is reachable"
      break
    fi
    now=$(date +%s)
    if [ $((now - start)) -ge "$T_WAIT_SERVER_SECONDS" ]; then
      log "❌ Timed out waiting for control-plane TCP ${SERVER_IP}:${SERVER_PORT} after ${T_WAIT_SERVER_SECONDS}s"
      exit 1
    fi
    sleep 5
  done
}

install_k3s_agent() {
  log "Installing K3s agent..."
  export K3S_TOKEN="$T_K3S_TOKEN"
  # K3S_URL expects scheme host:port
  if [[ "${T_K3S_SERVER}" == https://* ]] || [[ "${T_K3S_SERVER}" == http://* ]]; then
    export K3S_URL="${T_K3S_SERVER}"
  else
    export K3S_URL="https://${T_K3S_SERVER}"
  fi

  # Node-level params: node-ip, advertise-address optional
  local PARAMS="--node-ip ${PRIVATE_IP} --kubelet-arg=rotate-server-cert=true"
  # If you want the agent to run workloads on control-plane in single-node setups,
  # remove node taints on server script instead; here we keep agent default behavior.
  export INSTALL_K3S_EXEC="${PARAMS}"

  # Set version if provided
  if [ -n "${T_K3S_VERSION}" ]; then
    export INSTALL_K3S_VERSION="${T_K3S_VERSION}"
  fi

  # Run upstream installer (idempotent)
  curl -sfL https://get.k3s.io | sh - || {
    log "❌ k3s installer failed. Check /var/log/cloud-init-output.log and /var/log/messages"
    exit 1
  }

  log "k3s-agent install invoked. Waiting for k3s-agent service to be active..."
  local start now
  start=$(date +%s)
  while true; do
    if systemctl is-active --quiet k3s-agent; then
      log "✅ k3s-agent service is active"
      break
    fi
    now=$(date +%s)
    if [ $((now - start)) -ge "$T_WAIT_JOIN_SECONDS" ]; then
      log "❌ Timed out waiting for k3s-agent service to become active after ${T_WAIT_JOIN_SECONDS}s"
      journalctl -u k3s-agent -n 200 --no-pager || true
      exit 1
    fi
    sleep 3
  done

  # Wait for agent kubelet kubeconfig to exist as a sign the agent completed registration steps
  AGENT_CONFIG=/var/lib/rancher/k3s/agent/kubelet.kubeconfig
  start=$(date +%s)
  log "Waiting up to ${T_WAIT_JOIN_SECONDS}s for ${AGENT_CONFIG} to appear (agent joined)..."
  while true; do
    if [ -s "${AGENT_CONFIG}" ]; then
      log "✅ Agent kubelet kubeconfig present: ${AGENT_CONFIG}"
      break
    fi
    now=$(date +%s)
    if [ $((now - start)) -ge "$T_WAIT_JOIN_SECONDS" ]; then
      log "❌ Timed out waiting for agent kubelet kubeconfig to appear"
      journalctl -u k3s-agent -n 200 --no-pager || true
      exit 1
    fi
    sleep 3
  done

  log "Agent installation & basic join checks passed."
}

post_join_labeling() {
  # Optional: label the node once joined. This requires kubectl on the node that can talk to the cluster.
  # k3s provides kubectl as a wrapper. We will attempt to use it; if it's not appropriate for your setup,
  # remove or replace with a server-side process.
  if [ -n "${T_NODE_LABELS}" ]; then
    log "Applying node labels: ${T_NODE_LABELS}"
    # kubectl available via symlink to k3s binary
    KUBECTL_BIN="/usr/local/bin/kubectl"
    if [ -x "${KUBECTL_BIN}" ]; then
      # label the local node
      local node_name
      node_name=$(hostname)
      IFS=',' read -ra pairs <<< "$T_NODE_LABELS"
      for p in "${pairs[@]}"; do
        key=${p%%=*}
        val=${p#*=}
        log "Labeling node ${node_name} ${key}=${val} (non-fatal)"
        ${KUBECTL_BIN} label node "${node_name}" "${key}=${val}" --overwrite=true || true
      done
    else
      log "kubectl not present; skipping node labeling"
    fi
  fi
}

main() {
  install_base_tools
  disable_firewall
  get_private_ip
  wait_for_server_api_tcp
  install_k3s_agent
  post_join_labeling
  log "Agent setup complete."
}

main "$@"
