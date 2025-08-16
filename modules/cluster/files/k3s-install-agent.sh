#!/bin/bash

check_os() {
    name=$(cat /etc/os-release | grep ^NAME= | sed 's/"//g')
    clean_name=${name#*=}

    version=$(cat /etc/os-release | grep ^VERSION_ID= | sed 's/"//g')
    clean_version=${version#*=}
    major=${clean_version%.*}
    minor=${clean_version#*.}

    if [[ "$clean_name" == "Ubuntu" ]]; then
        operating_system="ubuntu"
    elif [[ "$clean_name" == "Oracle Linux Server" ]]; then
        operating_system="oraclelinux"
    else
        operating_system="undef"
    fi

    echo "K3S install process running on:"
    echo "  OS: $operating_system"
    echo "  OS Major Release: $major"
    echo "  OS Minor Release: $minor"
}

wait_lb() {
    while true; do
        curl --output /dev/null --silent -k https://${k3s_url}:6443
        if [[ "$?" -eq 0 ]]; then
            break
        fi
        sleep 5
        echo "wait for LB"
    done
}

install_helm() {
    curl -fsSL -o /root/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 /root/get_helm.sh
    /root/get_helm.sh
}

install_prometheus_stack() {
    echo "Installing kube-prometheus-stack (Prometheus + Grafana)..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update
    helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
        --namespace monitoring --create-namespace
}

install_argocd() {
    echo "Installing Argo CD..."
    kubectl create namespace argocd || true
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
}

install_postgresql() {
    echo "Installing PostgreSQL..."
    helm repo add bitnami https://charts.bitnami.com/bitnami
    helm repo update

    # DB credentials (override later if you want via values or env)
    POSTGRES_USER="newsappuser"
    POSTGRES_PASSWORD="$(openssl rand -hex 16)" # random secure password
    POSTGRES_DB="newsappdb"

    # Persist in a secret (so we can read back if re-run)
    kubectl create namespace database || true
    kubectl create secret generic postgres-secret \
        --from-literal=postgres-user=$POSTGRES_USER \
        --from-literal=postgres-password=$POSTGRES_PASSWORD \
        --from-literal=postgres-db=$POSTGRES_DB \
        -n database \
        --dry-run=client -o yaml | kubectl apply -f -

    # Install Postgres (primary service is ClusterIP)
    helm upgrade --install postgres bitnami/postgresql \
        --namespace database \
        --set global.postgresql.auth.username=$POSTGRES_USER \
        --set global.postgresql.auth.password=$POSTGRES_PASSWORD \
        --set global.postgresql.auth.database=$POSTGRES_DB \
        --set primary.service.type=ClusterIP
}

wait_for_postgres() {
    # Bitnami chart creates StatefulSet: postgres-postgresql
    echo "Waiting for PostgreSQL StatefulSet to be Ready..."
    kubectl -n database rollout status statefulset/postgres-postgresql --timeout=600s || true
}

create_db_uri_secret() {
    echo "Creating DB_URI secret for FE/BE pods..."

    # If vars not in scope (e.g., on re-run), read them from the secret
    if [[ -z "$POSTGRES_USER" || -z "$POSTGRES_PASSWORD" || -z "$POSTGRES_DB" ]]; then
        POSTGRES_USER=$(kubectl -n database get secret postgres-secret -o jsonpath='{.data.postgres-user}' | base64 -d)
        POSTGRES_PASSWORD=$(kubectl -n database get secret postgres-secret -o jsonpath='{.data.postgres-password}' | base64 -d)
        POSTGRES_DB=$(kubectl -n database get secret postgres-secret -o jsonpath='{.data.postgres-db}' | base64 -d)
    fi

    DB_ENGINE_TYPE="POSTGRES"
    # Correct FQDN for the primary svc: <release>-postgresql.<ns>.svc.cluster.local
    DB_URI="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres-postgresql.database.svc.cluster.local/${POSTGRES_DB}"

    TARGET_NS="default"   # change if your apps run elsewhere
    kubectl create namespace $TARGET_NS || true

    kubectl create secret generic app-db-connection \
        --from-literal=DB_ENGINE_TYPE=$DB_ENGINE_TYPE \
        --from-literal=DB_URI=$DB_URI \
        -n $TARGET_NS \
        --dry-run=client -o yaml | kubectl apply -f -
}

create_ingress_routes() {
    # Only if nginx ingress is enabled in this cluster
    if [[ "${ingress_controller}" == "nginx" ]]; then
        echo "Creating Ingress routes for Argo CD and Grafana..."

        # Argo CD at /argocd
        cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
    name: argocd
    namespace: argocd
    annotations:
        nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
        nginx.ingress.kubernetes.io/ssl-redirect: "false"
spec:
    ingressClassName: nginx
    rules:
    - http:
        paths:
        - path: /argocd
          pathType: Prefix
          backend:
            service:
              name: argocd-server
              port:
                number: 80
EOF

        # Grafana at /grafana
        cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
    name: grafana
    namespace: monitoring
    annotations:
        nginx.ingress.kubernetes.io/ssl-redirect: "false"
spec:
    ingressClassName: nginx
    rules:
    - http:
        paths:
        - path: /grafana
          pathType: Prefix
          backend:
            service:
              name: kube-prometheus-stack-grafana
              port:
                number: 80
EOF
    else
        echo "Ingress controller is not nginx; skipping Ingress creation."
    fi
}

wait_rollouts_basic() {
    # Best-effort rollout checks
    kubectl -n argocd rollout status deploy/argocd-server --timeout=600s || true
    kubectl -n monitoring rollout status deploy/kube-prometheus-stack-operator --timeout=600s || true
    kubectl -n monitoring rollout status deploy/kube-prometheus-stack-grafana  --timeout=600s || true
}

render_nginx_config(){
cat << 'EOF' > "$NGINX_RESOURCES_FILE"
---
apiVersion: v1
kind: Service
metadata:
    name: ingress-nginx-controller-loadbalancer
    namespace: ingress-nginx
spec:
    selector:
        app.kubernetes.io/component: controller
        app.kubernetes.io/instance: ingress-nginx
        app.kubernetes.io/name: ingress-nginx
    ports:
        - name: http
          port: 80
          protocol: TCP
          targetPort: 80
          nodePort: ${ingress_controller_http_nodeport}
        - name: https
          port: 443
          protocol: TCP
          targetPort: 443
          nodePort: ${ingress_controller_https_nodeport}
    type: NodePort
---
apiVersion: v1
data:
    allow-snippet-annotations: "true"
    enable-real-ip: "true"
    proxy-real-ip-cidr: "0.0.0.0/0"
    proxy-body-size: "20m"
    use-proxy-protocol: "true"
kind: ConfigMap
metadata:
    labels:
        app.kubernetes.io/component: controller
        app.kubernetes.io/instance: ingress-nginx
        app.kubernetes.io/managed-by: Helm
        app.kubernetes.io/name: ingress-nginx
        app.kubernetes.io/part-of: ingress-nginx
        app.kubernetes.io/version: 1.1.1
        helm.sh/chart: ingress-nginx-4.0.16
    name: ingress-nginx-controller
    namespace: ingress-nginx
EOF
}

install_and_configure_nginx(){
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-${nginx_ingress_release}/deploy/static/provider/baremetal/deploy.yaml
    NGINX_RESOURCES_FILE=/root/nginx-ingress-resources.yaml
    render_nginx_config
    kubectl apply -f $NGINX_RESOURCES_FILE
}

install_ingress(){
    INGRESS_CONTROLLER=$1
    if [[ "$INGRESS_CONTROLLER" == "nginx" ]]; then
        install_and_configure_nginx
    else
        echo "Ingress controller not supported"
    fi
}

check_os

if [[ "$operating_system" == "ubuntu" ]]; then
    echo "Canonical Ubuntu"
    # Disable firewall
    /usr/sbin/netfilter-persistent stop
    /usr/sbin/netfilter-persistent flush
    systemctl stop netfilter-persistent.service
    systemctl disable netfilter-persistent.service

    apt-get update
    apt-get install -y software-properties-common jq curl openssl
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y python3 python3-pip
    pip install oci-cli

    # Fix /var/log/journal dir size
    echo "SystemMaxUse=100M" >> /etc/systemd/journald.conf
    echo "SystemMaxFileSize=100M" >> /etc/systemd/journald.conf
    systemctl restart systemd-journald
fi

if [[ "$operating_system" == "oraclelinux" ]]; then
    echo "Oracle Linux"
    # Disable firewall
    systemctl disable --now firewalld

    # Fix iptables/SELinux bug
    echo '(allow iptables_t cgroup_t (dir (ioctl)))' > /root/local_iptables.cil
    semodule -i /root/local_iptables.cil

    dnf -y update
    if [[ $major -eq 9 ]]; then
        dnf -y install oraclelinux-developer-release-el9
        dnf -y install jq python39-oci-cli curl openssl
    else
        dnf -y install oraclelinux-developer-release-el8
        dnf -y module enable python36:3.6
        dnf -y install jq python36-oci-cli curl openssl
    fi
fi

export OCI_CLI_AUTH=instance_principal
first_instance=$(oci compute instance list --compartment-id ${compartment_ocid} --availability-domain ${availability_domain} --lifecycle-state RUNNING --sort-by TIMECREATED | jq -r '.data[]|select(."display-name" | endswith("k3s-servers")) | .["display-name"]' | tail -n 1)
instance_id=$(curl -s -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance | jq -r '.displayName')

k3s_install_params=("--tls-san ${k3s_tls_san}")

%{ if k3s_subnet != "default_route_table" }
local_ip=$(ip -4 route ls ${k3s_subnet} | grep -Po '(?<=src )(\S+)')
flannel_iface=$(ip -4 route ls ${k3s_subnet} | grep -Po '(?<=dev )(\S+)')

k3s_install_params+=("--node-ip $local_ip")
k3s_install_params+=("--advertise-address $local_ip")
k3s_install_params+=("--flannel-iface $flannel_iface")
%{ endif }

%{ if disable_ingress }
k3s_install_params+=("--disable traefik")
%{ endif }

%{ if ! disable_ingress }
%{ if ingress_controller != "default" }
k3s_install_params+=("--disable traefik")
%{ endif }
%{ endif }

%{ if expose_kubeapi }
k3s_install_params+=("--tls-san ${k3s_tls_san_public}")
%{ endif }

if [[ "$operating_system" == "oraclelinux" ]]; then
    k3s_install_params+=("--selinux")
fi

INSTALL_PARAMS="${k3s_install_params[*]}"

%{ if k3s_version == "latest" }
K3S_VERSION=$(curl --silent https://api.github.com/repos/k3s-io/k3s/releases/latest | jq -r '.name')
%{ else }
K3S_VERSION="${k3s_version}"
%{ endif }

if [[ "$first_instance" == "$instance_id" ]]; then
    echo "I'm the first yeeee: Cluster init!"
    until (curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION K3S_TOKEN=${k3s_token} sh -s - --cluster-init $INSTALL_PARAMS); do
        echo 'k3s did not install correctly'
        sleep 2
    done
else
    echo ":( Cluster join"
    wait_lb
    until (curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION K3S_TOKEN=${k3s_token} sh -s - --server https://${k3s_url}:6443 $INSTALL_PARAMS); do
        echo 'k3s did not install correctly'
        sleep 2
    done
fi

%{ if is_k3s_server }
until kubectl get pods -A | grep 'Running'; do
    echo 'Waiting for k3s startup'
    sleep 5
done

if [[ "$first_instance" == "$instance_id" ]]; then
    # ---- Optional: Longhorn (if enabled) ----
    %{ if install_longhorn }
    if [[ "$operating_system" == "ubuntu" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y open-iscsi curl util-linux
    fi
    systemctl enable --now iscsid.service
    kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/${longhorn_release}/deploy/longhorn.yaml
    %{ endif }

    # ---- Ingress controller (if enabled and not default Traefik) ----
    %{ if ! disable_ingress }
    %{ if ingress_controller != "default" }
    install_ingress ${ingress_controller}
    # Wait for nginx controller before creating routes
    kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s || true
    %{ endif }
    %{ endif }

    # ---- Helm + Control-plane add-ons ----
    install_helm
    install_postgresql
    wait_for_postgres
    create_db_uri_secret
    install_argocd
    install_prometheus_stack

    # ---- Ingress routes for Argo CD & Grafana ----
    create_ingress_routes

    # ---- Optional rollout checks ----
    wait_rollouts_basic

    echo "Argo CD and Grafana are being exposed via NGINX ingress:"
    echo "  - http(s)://<NLB_IP>/argocd"
    echo "  - http(s)://<NLB_IP>/grafana"
    echo "Argo CD initial admin password:"
    echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
fi
%{ endif }
