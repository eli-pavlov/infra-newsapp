#!/bin/bash
# RKE2 SERVER install, tooling, secret generation, ingress-nginx install,
# and Argo CD bootstrapping.
# Converted for Oracle Linux 9 (dnf-based).
set -euo pipefail
exec > /var/log/cloud-init-output.log 2>&1
set -x
trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR

# --- Terraform-injected vars (kept as template placeholders for templatefile) ---
T_RKE2_VERSION="${T_RKE2_VERSION}"
T_RKE2_TOKEN="${T_RKE2_TOKEN}"
T_DB_USER="${T_DB_USER}"
T_DB_NAME_DEV="${T_DB_NAME_DEV}"
T_DB_NAME_PROD="${T_DB_NAME_PROD}"
T_DB_SERVICE_NAME_DEV="${T_DB_SERVICE_NAME_DEV}"
T_DB_SERVICE_NAME_PROD="${T_DB_SERVICE_NAME_PROD}"
T_MANIFESTS_REPO_URL="${T_MANIFESTS_REPO_URL}"
T_EXPECTED_NODE_COUNT="${T_EXPECTED_NODE_COUNT}"
T_PRIVATE_LB_IP="${T_PRIVATE_LB_IP}"

install_base_tools() {
  echo "Installing base packages (dnf)..."
  dnf makecache --refresh -y || true
  dnf update -y
  dnf install -y curl jq git || true
}

# Best-effort disable firewalld (non-fatal)
systemctl disable firewalld --now || true

get_private_ip() {
  echo "Fetching instance private IP from metadata (OCI metadata endpoint)..."
  PRIVATE_IP=$(curl -s -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/vnics/ | jq -r '.[0].privateIp')
  if [ -z "$PRIVATE_IP" ] || [ "$PRIVATE_IP" = "null" ]; then
    echo "❌ Failed to fetch private IP."
    exit 1
  fi
  echo "✅ Instance private IP is $PRIVATE_IP"
}


# Ensure kernel modules, iptables, NetworkManager config, and sysctl needed for Canal
ensure_network_prereqs() {
  echo "==> Ensuring networking prerequisites (iptables, vxlan, sysctl, NetworkManager config)..."

  # Install iptables/xtables if missing (Canal requires iptables)
  if ! command -v iptables >/dev/null 2>&1; then
    echo "Installing iptables/xtables..."
    dnf install -y iptables iptables-services xtables-nft || dnf install -y iptables xtables-nft || true
  fi

  # Load vxlan kernel module (flannel/canal VXLAN)
  if ! lsmod | grep -q '^vxlan'; then
    modprobe vxlan || true
  fi

  # Ensure forwarding sysctl is persistent
  cat > /etc/sysctl.d/90-rke2.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
net.ipv6.conf.all.forwarding=1
EOF
  sysctl --system || true

  # Configure NetworkManager to ignore CNI-managed interfaces to avoid it interfering with veth/vxlan
  cat > /etc/NetworkManager/conf.d/rke2-canal.conf <<'EOF'
[keyfile]
unmanaged-devices=interface-name:flannel*;interface-name:cali*;interface-name:tunl*;interface-name:vxlan.calico;interface-name:vxlan-v6.calico;interface-name:wireguard.cali;interface-name:wg-v6.cali
EOF
  # reload NetworkManager (if present) to pick up unmanaged-devices
  if systemctl is-active --quiet NetworkManager; then
    systemctl reload NetworkManager || systemctl restart NetworkManager || true
  fi

  # Ensure CNI host paths exist (init container copies files into these paths)
  mkdir -p /opt/cni/bin /etc/cni/net.d /var/lib/calico /var/lib/cni
  chmod 755 /opt/cni/bin /etc/cni/net.d
  echo "==> Network prereqs done."
}


install_rke2_server() {
  echo "Installing RKE2 server..."

  # Export installer/version variables (from Terraform-injected placeholders)
  INSTALL_RKE2_VERSION="$T_RKE2_VERSION"
  INSTALL_RKE2_EXEC="server"
  export INSTALL_RKE2_VERSION INSTALL_RKE2_EXEC

  mkdir -p /etc/rancher/rke2
  chmod 700 /etc/rancher/rke2

  # Write RKE2 config (use shell variables for runtime values)
  cat > /etc/rancher/rke2/config.yaml <<EOF
token: $T_RKE2_TOKEN
node-ip: $PRIVATE_IP
advertise-address: $PRIVATE_IP
write-kubeconfig-mode: "0644"
tls-san:
  - $PRIVATE_IP
  - $T_PRIVATE_LB_IP
node-taint:
  - "node-role.kubernetes.io/control-plane=true:NoSchedule"
kubelet-arg:
  - "register-with-taints=node-role.kubernetes.io/control-plane=true:NoSchedule"
EOF

  echo "Running RKE2 installer (version: $INSTALL_RKE2_VERSION)..."
  curl -sfL https://get.rke2.io | sh -

  systemctl enable --now rke2-server.service

  echo "Waiting for RKE2 server node to be Ready..."
  kubectl_bin=/var/lib/rancher/rke2/bin/kubectl
  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
  sudo ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl

  start_time=$(date +%s)
  timeout=900
  while true; do
    if [ -x "$kubectl_bin" ] && "$kubectl_bin" --kubeconfig=/etc/rancher/rke2/rke2.yaml get nodes 2>/dev/null | grep -q 'Ready'; then
      echo "RKE2 server node is Ready."
      break
    fi
    elapsed=$(( $(date +%s) - start_time ))
    if [ "$elapsed" -gt "$timeout" ]; then
      printf '❌ Timed out waiting for RKE2 server node to become Ready (elapsed %ds).\n' "$elapsed"
      "$kubectl_bin" --kubeconfig=/etc/rancher/rke2/rke2.yaml cluster-info || true
      journalctl -u rke2-server -n 200 --no-pager || true
      exit 1
    fi
    printf 'Waiting for node Ready... (%d/%d s)\n' "$elapsed" "$timeout"
    sleep 5
  done
}

create_kubectl_wrapper() {
  echo "==> Locating rke2 kubectl binary..."
  # possible locations
  candidates=(
    /var/lib/rancher/rke2/bin/kubectl
    /var/lib/rancher/rke2/data/current/bin/kubectl
    /var/lib/rancher/rke2/data/*/bin/kubectl
  )

  found=""
  for c in "${candidates[@]}"; do
    for f in $(compgen -G "$c"); do
      [ -x "$f" ] && { found="$f"; break 2; }
    done
  done

  if [ -z "$found" ]; then
    echo "kubectl not yet available; will wait up to 120s..."
    retries=24
    while [ $retries -gt 0 ]; do
      for c in "${candidates[@]}"; do
        for f in $(compgen -G "$c"); do
          [ -x "$f" ] && { found="$f"; break 3; }
        done
      done
      sleep 5
      retries=$((retries-1))
    done
  fi

  if [ -z "$found" ]; then
    echo "Warning: rke2 kubectl binary not found after wait. Some kubectl calls may fail until RKE2 finishes extracting."
    return 0
  fi

  echo "Found kubectl at: $found"
  # create a small wrapper so users can run 'kubectl' without remembering kubeconfig location
  cat > /usr/local/bin/kubectl <<EOF
#!/bin/bash
# wrapper to call rke2 kubectl with the server kubeconfig
KUBECTL_BIN="${found}"
KUBECONFIG_FILE="/etc/rancher/rke2/rke2.yaml"

if [ ! -x "\$KUBECTL_BIN" ]; then
  echo "kubectl binary '\$KUBECTL_BIN' not found or not executable" >&2
  exit 2
fi

# If KUBECONFIG env is already set, respect it; otherwise use rke2 kubeconfig
if [ -n "$${KUBECONFIG:-}" ]; then
  exec "\$KUBECTL_BIN" "\$@"
else
  exec "\$KUBECTL_BIN" --kubeconfig="\$KUBECONFIG_FILE" "\$@"
fi
EOF
  chmod 0755 /usr/local/bin/kubectl
  echo "Created /usr/local/bin/kubectl wrapper."
}

# Remove cloudprovider 'uninitialized' taint which prevents system pods scheduling
remove_uninitialized_taint() {
  echo "==> Removing cloudprovider uninitialized taint (if present)..."
  # tolerant attempts to remove any variant
  if /usr/local/bin/kubectl get node "$${PRIVATE_HOSTNAME:-newsapp-control-plane}" &>/dev/null; then
    /usr/local/bin/kubectl taint nodes "$${PRIVATE_HOSTNAME:-newsapp-control-plane}" node.cloudprovider.kubernetes.io/uninitialized- || \
    /usr/local/bin/kubectl taint nodes "$${PRIVATE_HOSTNAME:-newsapp-control-plane}" node.cloudprovider.kubernetes.io/uninitialized:NoSchedule- || true
    echo "Taint removal attempted."
  else
    echo "kubectl cannot talk to API; skipping taint removal for now."
  fi
}

# Add toleration to rke2-canal daemonset so Canal can run on control-plane nodes
patch_canal_tolerations() {
  echo "==> Ensuring rke2-canal tolerates control-plane taint..."
  if ! /usr/local/bin/kubectl -n kube-system get daemonset rke2-canal >/dev/null 2>&1; then
    echo "rke2-canal not found yet, skipping patch (will rely on taint removal)."
    return 0
  fi

  # Check whether toleration already present
  if /usr/local/bin/kubectl -n kube-system get daemonset rke2-canal -o json | grep -q '"node-role.kubernetes.io/control-plane"'; then
    echo "toleration already exists on rke2-canal."
    return 0
  fi

  # Patch (strategic merge patch will merge tolerations)
  /usr/local/bin/kubectl -n kube-system patch daemonset rke2-canal --type='merge' -p '{
    "spec": {
      "template": {
        "spec": {
          "tolerations": [
            {"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}
          ]
        }
      }
    }
  }' || true

  echo "Patched rke2-canal tolerations (if api accepted). Deleting canal pods so they restart with new toleration..."
  /usr/local/bin/kubectl -n kube-system delete pod -l k8s-app=canal --ignore-not-found || true
  /usr/local/bin/kubectl -n kube-system rollout status daemonset/rke2-canal --timeout=5m || true
}

wait_for_kubeconfig_and_api() {
  echo "Waiting for kubeconfig and API to be fully ready (RKE2)..."
  timeout=120
  start_time=$(date +%s)
  kubectl_bin=/var/lib/rancher/rke2/bin/kubectl

  while true; do
    if [ ! -f /etc/rancher/rke2/rke2.yaml ]; then
      echo "Waiting for /etc/rancher/rke2/rke2.yaml to be created..."
      sleep 5
      continue
    fi

    if "$kubectl_bin" --kubeconfig=/etc/rancher/rke2/rke2.yaml get nodes 2>/dev/null | grep -q 'Ready'; then
      if "$kubectl_bin" --kubeconfig=/etc/rancher/rke2/rke2.yaml get pods -n kube-system 2>/dev/null | grep -qE '(etcd|coredns|kube-proxy|kube-scheduler|kube-controller)'; then
        echo "✅ RKE2 kubeconfig and API are ready."
        break
      fi
    fi

    elapsed_time=$(( $(date +%s) - start_time ))
    if [ "$elapsed_time" -gt "$timeout" ]; then
      printf '❌ Timed out waiting for RKE2 kubeconfig and API readiness (%ds).\n' "$elapsed_time"
      "$kubectl_bin" --kubeconfig=/etc/rancher/rke2/rke2.yaml cluster-info || true
      exit 1
    fi

    printf '(%d/%d s) Waiting for RKE2 kubeconfig and API readiness...\n' "$elapsed_time" "$timeout"
    sleep 5
  done
}

wait_for_all_nodes() {
  echo "Waiting for all $T_EXPECTED_NODE_COUNT nodes to join and become Ready..."
  timeout=1800
  start_time=$(date +%s)
  while true; do
    ready_nodes=$(/usr/local/bin/kubectl get nodes --no-headers 2>/dev/null \
      | awk '{print $2}' | grep -Ec '^Ready(,SchedulingDisabled)?$' || true)
    if [ "$ready_nodes" -eq "$T_EXPECTED_NODE_COUNT" ]; then
      echo "✅ All $T_EXPECTED_NODE_COUNT nodes are Ready. Proceeding."
      break
    fi
    elapsed_time=$(( $(date +%s) - start_time ))
    if [ "$elapsed_time" -gt "$timeout" ]; then
      echo "❌ Timed out waiting for all nodes to become Ready."
      /usr/local/bin/kubectl get nodes || true
      exit 1
    fi
    printf '(%d/%d s) Currently %d/%s nodes are Ready. Waiting...\n' "$elapsed_time" "$timeout" "$ready_nodes" "$T_EXPECTED_NODE_COUNT"
    sleep 15
  done
}

install_helm() {
  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
  if ! command -v helm &> /dev/null; then
    echo "Installing Helm..."
    curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 /tmp/get_helm.sh
    /tmp/get_helm.sh
    rm -f /tmp/get_helm.sh
  fi
}

install_ingress_nginx() {
  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
  echo "Installing ingress-nginx via Helm (DaemonSet + NodePorts 30080/30443)..."
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm repo update
  /usr/local/bin/kubectl create namespace ingress-nginx || true

  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --set controller.kind=DaemonSet \
    --set controller.service.type=NodePort \
    --set controller.service.nodePorts.http=30080 \
    --set controller.service.nodePorts.https=30443 \
    --set controller.service.externalTrafficPolicy=Local \
    --set controller.nodeSelector.role=application \
    --set controller.ingressClassResource.name=nginx \
    --set controller.ingressClassByName=true

  echo "Waiting for ingress-nginx controller rollout..."
  /usr/local/bin/kubectl -n ingress-nginx rollout status ds/ingress-nginx-controller --timeout=5m
}

install_argo_cd() {
  echo "Installing Argo CD..."
  /usr/local/bin/kubectl create namespace argocd || true
  /usr/local/bin/kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

  # Tolerate control-plane taint where applicable
  for d in argocd-server argocd-repo-server argocd-dex-server; do
    /usr/local/bin/kubectl -n argocd patch deployment "$d" --type='json' -p='[
      {"op":"add","path":"/spec/template/spec/tolerations","value":[
        {"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}
      ]}
    ]' || true
  done

  /usr/local/bin/kubectl -n argocd patch statefulset argocd-application-controller --type='json' -p='[
    {"op":"add","path":"/spec/template/spec/tolerations","value":[
      {"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule