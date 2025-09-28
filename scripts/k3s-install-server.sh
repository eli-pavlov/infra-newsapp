#!/bin/bash
# K3s SERVER install, tooling, secret generation, ingress-nginx install,
# and Argo CD bootstrapping.

# --- Script Configuration and Error Handling ---

# Set shell options for robust error handling.
# -e: Exit immediately if a command exits with a non-zero status.
# -u: Treat unset variables as an error when substituting.
# -o pipefail: The return value of a pipeline is the status of the last command to exit with a non-zero status,
#              or zero if no command exited with a non-zero status.
set -euo pipefail

# Redirect all standard output and standard error to a log file for persistent logging.
# This is more robust than `tee` as it avoids potential SIGPIPE issues.
exec > /var/log/cloud-init-output.log 2>&1

# Set up a trap to report the line number and command that failed before exiting.
# This is invaluable for debugging script failures.
trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR

# --- Vars injected by Terraform ---
# These variables are placeholders that are dynamically replaced by Terraform
# during the cloud-init rendering process. They provide necessary configuration
# values for the cluster setup.
T_K3S_VERSION="${T_K3S_VERSION}"
T_K3S_TOKEN="${T_K3S_TOKEN}"
T_MANIFESTS_REPO_URL="${T_MANIFESTS_REPO_URL}"
T_EXPECTED_NODE_COUNT="${T_EXPECTED_NODE_COUNT}"
T_PRIVATE_LB_IP="${T_PRIVATE_LB_IP}"
T_SEALED_SECRETS_CERT="${T_SEALED_SECRETS_CERT}"
T_SEALED_SECRETS_KEY="${T_SEALED_SECRETS_KEY}"

# Enable command tracing. 'set -x' prints each command to stderr before it is executed.
# Useful for debugging the script's execution flow.
set -x

# --- Function Definitions ---

# Installs essential command-line tools required for the script.
install_base_tools() {
  echo "Installing base packages (dnf)..."
  # Refresh the dnf cache. `|| true` prevents the script from exiting if this fails.
  dnf makecache --refresh -y || true
  # Update all system packages.
  dnf update -y
  # Install curl, jq (for JSON parsing), and git.
  dnf install -y curl jq git || true
}

# Disable the system firewall. K3s manages its own networking rules via iptables,
# so firewalld can interfere. `|| true` prevents an error if the service is already disabled.
systemctl disable firewalld --now || true

# Retrieves the private IP address of the instance from the OCI metadata service.
# This IP is crucial for K3s to advertise itself correctly within the VPC.
get_private_ip() {
  echo "Fetching instance private IP from metadata (OCI metadata endpoint)..."
  # Curl the metadata endpoint and parse the JSON response with jq to extract the private IP.
  PRIVATE_IP=$(curl -s -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/vnics/ | jq -r '.[0].privateIp')
  # Validate that the IP was successfully retrieved.
  if [ -z "$PRIVATE_IP" ] || [ "$PRIVATE_IP" = "null" ]; then
    echo "❌ Failed to fetch private IP."
    exit 1
  fi
  echo "✅ Instance private IP is $PRIVATE_IP"
}

# Installs the K3s server component.
install_k3s_server() {
  echo "Installing K3s server..."
  local PARAMS="--write-kubeconfig-mode 644 \
    --node-ip $PRIVATE_IP \
    --advertise-address $PRIVATE_IP \
    --disable traefik \
    --tls-san $PRIVATE_IP \
    --tls-san $T_PRIVATE_LB_IP \
    --kubelet-arg=register-with-taints=node-role.kubernetes.io/control-plane=true:NoSchedule"

  export INSTALL_K3S_EXEC="$PARAMS"
  export K3S_TOKEN="$T_K3S_TOKEN"
  export INSTALL_K3S_VERSION="$T_K3S_VERSION"

  curl -sfL https://get.k3s.io | sh -

  # ensure kubectl will point at the freshly created kubeconfig
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

  # wait for kubeconfig file to exist before any kubectl calls
  local wait=0
  while [ ! -f "$KUBECONFIG" ] && [ $wait -lt 60 ]; do
    sleep 2; wait=$((wait+2))
  done

  echo "Waiting for K3s server node to be Ready (this may take a minute)..."
  # wait up to 5 minutes for the node to show Ready
  local start=$(date +%s)
  while ! /usr/local/bin/kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -q '^Ready'; do
    sleep 5
    if [ $(( $(date +%s) - start )) -gt 300 ]; then
      echo "Timeout waiting for node to become Ready."
      /usr/local/bin/kubectl get nodes || true
      break
    fi
  done

  # If the node is tainted control-plane, ensure kube-proxy tolerates it.
  if /usr/local/bin/kubectl get nodes -o jsonpath='{.items[*].spec.taints}' 2>/dev/null | grep -q 'node-role.kubernetes.io/control-plane'; then
    echo "Detected control-plane taint on nodes — ensuring kube-proxy toleration..."
    /usr/local/bin/kubectl -n kube-system patch daemonset kube-proxy --type='merge' -p '{
      "spec":{"template":{"spec":{"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}}}}' || {
        echo "Warning: patch failed or kube-proxy DaemonSet not yet created; will try again later."
      }
  fi

  echo "K3s server install completed."
}

# Waits for the kubeconfig file to be created and for the Kubernetes API server to become responsive.
wait_for_kubeconfig_and_api() {
  echo "Waiting for kubeconfig and API readiness..."
  local timeout=120
  local start_time
  start_time=$(date +%s)
  while true; do
    # Check if the kubeconfig file exists.
    if [ ! -f /etc/rancher/k3s/k3s.yaml ]; then
      echo "Waiting for kubeconfig file..."
      sleep 5
      continue
    fi
    # Check if the API server is responsive and nodes are reporting.
    if /usr/local/bin/kubectl get nodes 2>/dev/null | grep -q 'Ready'; then
      # A light check to ensure core Kubernetes components are running.
      if /usr/local/bin/kubectl get pods -n kube-system 2>/dev/null | grep -qE '(etcd|coredns|kube-proxy|kube-scheduler|kube-controller)'; then
        echo "✅ Kubeconfig + API are ready."
        break
      fi
    fi
    # Timeout logic to prevent the script from hanging indefinitely.
    local elapsed_time=$(( $(date +%s) - start_time ))
    if [ "$elapsed_time" -gt "$timeout" ]; then
      echo "❌ Timed out waiting for kubeconfig/API"
      /usr/local/bin/kubectl cluster-info || true
      exit 1
    fi
    sleep 5
  done
  kubectl label node newsapp-control-plane role=control-plane --overwrite
}

# Waits until the expected number of nodes have joined the cluster and are in a 'Ready' state.
wait_for_all_nodes() {
  echo "Waiting for all $T_EXPECTED_NODE_COUNT nodes to join and become Ready..."
  local timeout=900 # 15 minutes
  local start_time; start_time=$(date +%s)
  while true; do
    # Count the number of nodes that are 'Ready' or 'Ready,SchedulingDisabled'.
    local ready_nodes
    ready_nodes=$(/usr/local/bin/kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -Ec '^Ready(,SchedulingDisabled)?$' || true)
    if [ "$ready_nodes" -eq "$T_EXPECTED_NODE_COUNT" ]; then
      echo "✅ All $T_EXPECTED_NODE_COUNT nodes are Ready."
      break
    fi
    # Timeout logic.
    local elapsed_time=$(( $(date +%s) - start_time ))
    if [ "$elapsed_time" -gt "$timeout" ]; then
      echo "❌ Timed out waiting for nodes to become Ready."
      /usr/local/bin/kubectl get nodes || true
      exit 1
    fi
    echo "($elapsed_time/$timeout s) $ready_nodes/$T_EXPECTED_NODE_COUNT ready; sleeping 15s..."
    sleep 15
  done
}

# Installs Helm, the Kubernetes package manager.
install_helm() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  export PATH=$PATH:/usr/local/bin
  # Check if Helm is already installed before attempting to install.
  if ! command -v helm &> /dev/null; then
    echo "Installing Helm..."
    curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 /tmp/get_helm.sh
    /tmp/get_helm.sh
    rm -f /tmp/get_helm.sh
  fi
}

# Installs and configures an Argo CD instance using its official Helm chart.
bootstrap_argo_cd_instance() {
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    echo "Bootstrapping Argo CD instance directly via Helm..."

    # 1. Create necessary namespaces for Argo CD and applications.
    /usr/local/bin/kubectl create namespace argocd --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f -
    /usr/local/bin/kubectl create namespace development --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f -

    # 2. Add the official Argo Project Helm repository.
    /usr/local/bin/helm repo add argo https://argoproj.github.io/argo-helm
    /usr/local/bin/helm repo update

    # 3. Install Argo CD using Helm, overriding default values.
    /usr/local/bin/helm install argocd argo/argo-cd \
        --version 8.3.7 \
        --namespace argocd \
        \
        `# Ingress Configuration: Expose the Argo CD server via an Ingress resource.` \
        --set server.ingress.enabled=true \
        --set server.ingress.ingressClassName=nginx \
        --set server.ingress.hostname="argocd.weblightenment.com" \
        --set server.ingress.annotations."nginx\.ingress\.kubernetes\.io/backend-protocol"=HTTP \
        --set server.ingress.annotations."nginx\.ingress\.kubernetes\.ioio/force-ssl-redirect"=true \
        --set server.ingress.tls[0].secretName=argocd-tls \
        --set server.ingress.tls[0].hosts[0]="argocd.weblightenment.com" \
        \
        `# Server Configuration: Run in insecure mode as TLS is terminated at the ingress.` \
        --set server.extraArgs='{--insecure}' \
        \
        `# Tolerations: Allow Argo CD pods to be scheduled on the control-plane node.` \
        --set server.tolerations[0].key="node-role.kubernetes.io/control-plane" \
        --set server.tolerations[0].operator="Exists" \
        --set server.tolerations[0].effect="NoSchedule" \
        --set controller.tolerations[0].key="node-role.kubernetes.io/control-plane" \
        --set controller.tolerations[0].operator="Exists" \
        --set controller.tolerations[0].effect="NoSchedule" \
        --set repoServer.tolerations[0].key="node-role.kubernetes.io/control-plane" \
        --set repoServer.tolerations[0].operator="Exists" \
        --set repoServer.tolerations[0].effect="NoSchedule" \
        --set dex.tolerations[0].key="node-role.kubernetes.io/control-plane" \
        --set dex.tolerations[0].operator="Exists" \
        --set dex.tolerations[0].effect="NoSchedule" \
        --set redis.tolerations[0].key="node-role.kubernetes.io/control-plane" \
        --set redis.tolerations[0].operator="Exists" \
        --set redis.tolerations[0].effect="NoSchedule"

    # 4. Wait for the Argo CD server deployment to become available.
    echo "Waiting for Argo CD to become available..."
    /usr/local/bin/kubectl wait --for=condition=Available -n argocd deployment/argocd-server --timeout=5m
}

# Generates secrets and credentials needed by the applications.
install_sealed_secrets() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  
  # --- Sealed Secrets Setup ---
  # 1. Add the Sealed Secrets Helm repository.
  helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
  helm repo update

  # 2. Pull the chart locally to apply CRDs separately.
  helm pull sealed-secrets/sealed-secrets --version 2.17.6 --untar --untardir /tmp

  # 3. Apply Custom Resource Definitions before installing the controller. This is a best practice.
  kubectl apply -f /tmp/sealed-secrets/crds

  # 4. Verify CRD installation.
  kubectl get crd | grep -i sealed

  # --- Kubeseal CLI Installation ---
  # Fetch the latest version tag from GitHub API and install the kubeseal CLI.
  KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/tags | jq -r '.[0].name' | cut -c 2-)

  if [ -z "$KUBESEAL_VERSION" ]; then
      echo "Failed to fetch the latest KUBESEAL_VERSION"
      exit 1
  fi
  curl -OL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v$${KUBESEAL_VERSION}/kubeseal-$${KUBESEAL_VERSION}-linux-arm64.tar.gz"
  tar -xvzf kubeseal-$${KUBESEAL_VERSION}-linux-arm64.tar.gz kubeseal
  sudo install -m 755 kubeseal /usr/local/bin/kubeseal

  # --- Sealed Secrets Master Key Injection ---
  # Create/update the master TLS secret for Sealed Secrets from Terraform variables.
  if [ -z "${T_SEALED_SECRETS_CERT}" ] || [ -z "${T_SEALED_SECRETS_KEY}" ]; then
    echo "ERROR: T_SEALED_SECRETS_CERT and T_SEALED_SECRETS_KEY must be set." >&2
    exit 2
  fi

  # Use a temporary directory for securely handling the key/cert files.
  TMPDIR=$(mktemp -d /tmp/sealed-secret.XXXXXX) || { echo "ERROR: failed to create temp dir" >&2; exit 4; }
  CRT_PATH="$TMPDIR/sealed-secrets.crt"
  KEY_PATH="$TMPDIR/sealed-secrets.key"

  # Decode the base64 encoded cert and key provided by Terraform.
  if command -v base64 >/dev/null 2>&1 && base64 --help 2>&1 | grep -q -E '(-d|--decode)'; then
    printf '%s' "${T_SEALED_SECRETS_CERT}" | base64 --decode > "$CRT_PATH" || { echo "ERROR: decode cert failed" >&2; rm -rf "$TMPDIR"; exit 5; }
    printf '%s' "${T_SEALED_SECRETS_KEY}"  | base64 --decode > "$KEY_PATH" || { echo "ERROR: decode key failed" >&2; rm -rf "$TMPDIR"; exit 6; }
  else
    # Fallback to Python if a standard `base64 --decode` is not available.
    python3 -c 'import sys,base64; open(sys.argv[1],"wb").write(base64.b64decode(sys.argv[2].encode())); open(sys.argv[3],"wb").write(base64.b64decode(sys.argv[4].encode()))' \
      "$CRT_PATH" "${T_SEALED_SECRETS_CERT}" "$KEY_PATH" "${T_SEALED_SECRETS_KEY}" \
      || { echo "ERROR: python decode failed" >&2; rm -rf "$TMPDIR"; exit 7; }
  fi

  chmod 600 "$CRT_PATH" "$KEY_PATH" || true

  # Apply the TLS secret to the cluster for the Sealed Secrets controller to use.
  /usr/local/bin/kubectl -n kube-system create secret tls sealed-secrets-key \
    --cert="$CRT_PATH" --key="$KEY_PATH" \
    --dry-run=client -o yaml | /usr/local/bin/kubectl apply -f - || { echo "ERROR: kubectl apply failed" >&2; rm -rf "$TMPDIR"; exit 8; }
  
  # Label the secret to mark it as the active key for encryption.
  /usr/local/bin/kubectl -n kube-system label secret sealed-secrets-key \
    sealedsecrets.bitnami.com/sealed-secrets-key=active --overwrite || true
  echo "Applied sealed-secrets key in kube-system."

  # Clean up the temporary directory.
  rm -rf "$TMPDIR" || true
}

# Clones the Git repository containing Kubernetes manifests and applies the root Argo CD application.
bootstrap_argocd_apps() {
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo "Bootstrapping Argo CD Applications from manifests repo: ${T_MANIFESTS_REPO_URL}"
  
  TMP_MANIFESTS_DIR="/tmp/newsapp-manifests"
  # Check if a local clone of the repo already exists.
  if [ -d "$TMP_MANIFESTS_DIR/.git" ]; then
    echo "Local clone exists; attempting git -C pull..."
    # If it exists, pull the latest changes.
    git -C "$TMP_MANIFESTS_DIR" pull --ff-only || true
  else
    # Otherwise, clone the repository. Continue even if clone fails, as Argo CD can fetch remotely.
    if ! git clone --depth 1 "${T_MANIFESTS_REPO_URL}" "$TMP_MANIFESTS_DIR"; then
      echo "Warning: git clone failed for ${T_MANIFESTS_REPO_URL}; continuing..."
    fi
  fi
  
  # Temporarily disable exit-on-error to allow kubectl apply to fail without halting the script.
  set +e
  # Apply the root "App of Apps" manifest, which tells Argo CD to manage all other applications.
    if [ -f "$TMP_MANIFESTS_DIR/newsapp-master-app.yaml" ]; then
    /usr/local/bin/kubectl apply -f "$TMP_MANIFESTS_DIR/newsapp-master-app.yaml"  
    else
      echo "❌ newsapp-master-app.yaml not found in repository. Cannot bootstrap Argo CD."
      exit 1
    fi
  # Re-enable exit-on-error.
  set -e


  ### --- Save credentials --- ###
  echo "Generating credentials"
  # --- Argo CD Initial Password Retrieval ---
  ARGO_PASSWORD=$(/usr/local/bin/kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null || echo "")
  if [ -n "$ARGO_PASSWORD" ]; then
    ARGO_PASSWORD=$(echo "$ARGO_PASSWORD" | base64 -d)
  else
    ARGO_PASSWORD="(unknown)"s
  fi

  # --- Dynamic Database Secret Retrieval ---
  # Retrieve the database user from the specified secret and namespace.
  DB_USER=$(/usr/local/bin/kubectl -n default get secret db-user -o jsonpath="{.data.DB_USER}" 2>/dev/null || echo "")
  if [ -n "$DB_USER" ]; then
    DB_USER=$(echo "$DB_USER" | base64 -d)
  else
    DB_USER="(unknown)"
  fi

  # Retrieve the database password from the specified secret and namespace.
  DB_PASSWORD=$(/usr/local/bin/kubectl -n default get secret db-password -o jsonpath="{.data.DB_PASSWORD}" 2>/dev/null || echo "")
  if [ -n "$DB_PASSWORD" ]; then
    DB_PASSWORD=$(echo "$DB_PASSWORD" | base64 -d)
  else
    DB_PASSWORD="(unknown)"
  fi

  # --- Credentials File Creation ---
  # Create a file on the server with all retrieved credentials for admin access.
  cat << EOF > /home/opc/credentials.txt
# --- Argo CD Admin Credentials ---
Username: admin
Password: $${ARGO_PASSWORD}

# --- Database Credentials ---
DB User: $${DB_USER}
DB Password: $${DB_PASSWORD}
EOF

  # Wait for the root application to become Healthy in Argo CD.
  echo "Waiting up to 15m for applications to become Healthy..."
  /usr/local/bin/kubectl -n argocd wait --for=condition=Healthy application/newsapp-master-app --timeout=15m
  echo "Argo CD Application CRs applied."
}


# --- Main Execution Logic ---
# The main function orchestrates the execution of all setup steps in the correct order.
main() {
  install_base_tools
  get_private_ip
  install_k3s_server
  wait_for_kubeconfig_and_api
  wait_for_all_nodes
  install_helm
  bootstrap_argo_cd_instance
  install_sealed_secrets
  bootstrap_argocd_apps
}

# Execute the main function, passing any script arguments to it.
main "$@"
