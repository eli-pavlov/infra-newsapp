<div align="center">
  <img src="https://raw.githubusercontent.com/devicons/devicon/master/icons/oracle/oracle-original.svg" alt="OCI Logo" width="100" height="100"/>
  <img src="https://raw.githubusercontent.com/devicons/devicon/master/icons/terraform/terraform-original.svg" alt="Terraform Logo" width="100" height="100"/>
  <img src="https://raw.githubusercontent.com/devicons/devicon/master/icons/kubernetes/kubernetes-plain.svg" alt="Kubernetes Logo" width="100" height="100"/>
  <img src="https://www.vectorlogo.zone/logos/cloudflare/cloudflare-icon.svg" alt="Cloudflare Logo" width="100" height="100"/>
  <img src="https://raw.githubusercontent.com/devicons/devicon/master/icons/github/github-original.svg" alt="GitHub Actions Logo" width="100" height="100"/>

  <h1>OCI K3s Infrastructure with Terraform & GitHub Actions</h1>
</div>

This repository contains a comprehensive Terraform setup to provision a complete K3s Kubernetes cluster on **Oracle Cloud Infrastructure (OCI)**. The entire lifecycle of the infrastructure—from state bucket creation to cluster deployment and destruction—is automated using a suite of **GitHub Actions workflows**.

<p align="center">
  <img src="https://img.shields.io/github/actions/workflow/status/YOUR_USERNAME/YOUR_REPONAME/Stack%20-%20plan.yml?branch=main&label=Terraform%20Plan&style=for-the-badge" alt="Terraform Plan Status"/>
  <img src="https://img.shields.io/github/actions/workflow/status/YOUR_USERNAME/YOUR_REPONAME/Stack%20-%20apply.yml?label=Terraform%20Apply&style=for-the-badge" alt="Terraform Apply Status"/>
  <img src="https://img.shields.io/github/actions/workflow/status/YOUR_USERNAME/YOUR_REPONAME/Stack-%20destroy.yml?label=Terraform%20Destroy&style=for-the-badge" alt="Terraform Destroy Status"/>
</p>

---

## 🚀 Features

-   **Fully Automated Lifecycle**: All infrastructure provisioning and management is handled through GitHub Actions.
-   **Segregated Workspaces**: Terraform code is split into logical workspaces (`bootstrap`, `storage`, `stack`) for clarity and safety.
-   **Secure Network Design**: Utilizes a VCN with public and private subnets, Network Security Groups (NSGs), and a bastion host for secure management access.
-   **High Availability Ready**: A private load balancer fronts the K3s control plane, and a public NLB exposes application ingress controllers.
-   **Persistent Storage**: Manages a dedicated OCI Block Volume for stateful workloads like databases.
-   **GitOps Ready**: The control plane bootstrap script automatically installs and configures Argo CD to manage applications from a Git repository.
-   **Automated DNS & Security**: Manages Cloudflare DNS records and firewall rules for exposed services.

---

## 🏗️ Architecture Overview

The infrastructure consists of the following core components within a single OCI Virtual Cloud Network (VCN):

-   **Public Subnet**: Hosts the Bastion instance and the public-facing Network Load Balancer (NLB).
-   **Private Subnet**: Hosts all K3s nodes (control plane and workers) and the private classic load balancer for the Kubernetes API.
-   **Bastion Host**: A single entry point for SSH access to the private nodes.
-   **K3s Cluster**:
    -   1 Control Plane Node
    -   2 Application Worker Nodes
    -   1 Database Worker Node (with a dedicated block volume attached)
-   **Load Balancers**:
    -   **Public NLB**: Forwards internet traffic (ports 80/443) to the NGINX ingress controller's NodePorts on the app workers.
    -   **Private LB**: Provides a stable internal endpoint for the Kubernetes API server (port 6443), used by worker nodes and internal tools.
-   **OCI Object Storage**: Used as the backend for Terraform's remote state.
-   **Cloudflare Integration**: Serves as the public entry point for all application traffic. Terraform manages:
    -   **DNS A Records**: Automatically points hostnames like `argocd.*`, `newsapp.*`, etc., to the public Network Load Balancer. All records are proxied through Cloudflare, enabling caching and security features.
    -   **Firewall Rules (WAF)**: Provides a critical security layer by:
        -   Restricting access to administrative endpoints (Argo CD, Grafana, pgAdmin) to only the IP addresses defined in the `ADMIN_CIDRS` secret.
        -   Geo-blocking access to the main application, allowing traffic only from specified countries (e.g., Israel).
    -   **Automated TLS**: The control plane setup script creates a Kubernetes secret with the Cloudflare API token. This enables `cert-manager` (deployed via GitOps) to automatically issue and renew public TLS certificates using the DNS-01 challenge, ensuring secure connections to all services.

---

## ⚙️ Setup and Configuration

Before you can deploy the infrastructure, you must configure the required secrets in your GitHub repository.

➡️ Navigate to `Settings` > `Secrets and variables` > `Actions` and add the following repository secrets.

### **OCI Authentication**

| Secret                    | Description                                                                                             | Example                                                            |
| ------------------------- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| `OCI_TENANCY_OCID`        | The OCID of your OCI tenancy.                                                                           | `ocid1.tenancy.oc1..aaaa...`                                       |
| `OCI_USER_OCID`           | The OCID of the API user.                                                                               | `ocid1.user.oc1..aaaa...`                                          |
| `OCI_FINGERPRINT`         | The fingerprint of the API public key.                                                                  | `12:34:56:78:90:ab:cd:ef...`                                       |
| `OCI_PRIVATE_KEY_PEM`     | The **full content** of the PEM-formatted private key file for the API user.                              | `-----BEGIN PRIVATE KEY-----\n...your key data...\n-----END...`     |
| `OCI_REGION`              | The OCI region where resources will be deployed.                                                        | `us-ashburn-1`                                                     |
| `COMPARTMENT_OCID`        | The OCID of the compartment to deploy resources into.                                                   | `ocid1.compartment.oc1..aaaa...`                                   |
| `OS_NAMESPACE`            | Your OCI Object Storage namespace.                                                                      | `axaxixbxcx`                                                       |
| `AVAILABILITY_DOMAIN`     | The availability domain for compute and storage resources.                                              | `Uocm:US-ASHBURN-AD-1`                                             |
| `OS_IMAGE_ID`             | The OCID of the Oracle Linux image for K3s nodes.                                                       | `ocid1.image.oc1.iad..aaaa...`                                     |
| `BASTION_IMAGE`           | The OCID of the Oracle Linux image for the bastion host.                                                | `ocid1.image.oc1.iad..aaaa...`                                     |

### **Terraform State & Cluster Configuration**

| Secret                  | Description                                                                                       | Example                                                |
| ----------------------- | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| `TF_STATE_BUCKET`       | A unique name for the OCI Object Storage bucket that will store the Terraform state.              | `my-k3s-cluster-tfstate`                               |
| `TF_STATE_KEY`          | The object name for the main stack's state file within the bucket.                                | `newsapp.tfstate`                                      |
| `CLUSTER_NAME`          | A name for your K3s cluster.                                                                      | `newsapp-prod`                                         |
| `MANIFESTS_REPO_URL`    | The HTTPS URL of the Git repository containing your Kubernetes manifests for Argo CD.             | `https://github.com/user/my-k8s-manifests.git`         |
| `DB_STORAGE_OCID`       | **(Optional)** The OCID of an existing Block Volume to import. Leave empty to create a new one. | `ocid1.volume.oc1.iad..aaaa...`                          |

### **Network & DNS**

| Secret                   | Description                                                                                                                                     | Example                                                              |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `ADMIN_CIDRS`            | A JSON array of IP addresses/CIDRs that are allowed SSH access to the bastion and access to protected endpoints like Argo CD.                     | `["1.2.3.4/32", "5.6.7.0/24"]`                                        |
| `CLOUDFLARE_CIDRS`       | A JSON array of Cloudflare's IP ranges. This is used to restrict traffic to the public load balancer. [Get them here](https://www.cloudflare.com/ips/). | `["173.245.48.0/20", ...]`                                           |
| `CLOUDFLARE_API_TOKEN`   | Your Cloudflare API token with DNS edit permissions.                                                                                            | `_bM...`                                                             |
| `CLOUDFLARE_ZONE_ID`     | The Zone ID of your domain in Cloudflare.                                                                                                       | `a1b2c3d4e5f6...`                                                    |

### **Application & External Services**

| Secret                    | Description                                                                                                  | Example                               |
| ------------------------- | ------------------------------------------------------------------------------------------------------------ | ------------------------------------- |
| `AWS_ACCESS_KEY_ID`       | AWS Access Key for S3 bucket access (used by applications).                                                  | `AKIAIOSFODNN7EXAMPLE`                |
| `AWS_SECRET_ACCESS_KEY`   | AWS Secret Access Key for S3 bucket access.                                                                  | `wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLE` |
| `AWS_REGION`              | The AWS region of the S3 bucket.                                                                             | `us-east-1`                           |
| `AWS_BUCKET`              | The name of the S3 bucket.                                                                                   | `my-app-data-bucket`                  |
| `STORAGE_TYPE`            | The storage type for the application (e.g., `s3`).                                                           | `s3`                                  |
| `SEALED_SECRETS_CERT`     | The **base64-encoded** public certificate for the Sealed Secrets controller. See notes below.                | `LS0tLS1...`                          |
| `SEALED_SECRETS_KEY`      | The **base64-encoded** private key for the Sealed Secrets controller. See notes below.                       | `LS0tLS1...`                          |

<details>
<summary>🔑 <b>How to Generate Sealed Secrets Keys</b></summary>

The `k3s-install-server.sh` script requires a pre-generated keypair to bootstrap the Sealed Secrets controller, ensuring the key is persistent across re-deployments.

1.  **Generate the key and certificate:**
    ```sh
    openssl req -x509 -nodes -newkey rsa:4096 -keyout tls.key -out tls.crt -subj "/CN=sealed-secret"
    ```

2.  **Base64 encode the files for GitHub Secrets:**
    * On **Linux**:
        ```sh
        cat tls.crt | base64 -w 0
        cat tls.key | base64 -w 0
        ```
    * On **macOS**:
        ```sh
        cat tls.crt | base64
        cat tls.key | base64
        ```

3.  Copy the output of the first command into the `SEALED_SECRETS_CERT` secret and the second into the `SEALED_SECRETS_KEY` secret.
</details>

---

## ▶️ How to Deploy

The infrastructure must be deployed in a specific order by running the GitHub Actions workflows manually.

### **Step 1: Bootstrap the State Bucket** 🪣

This workflow creates the OCI Object Storage bucket where all Terraform state files will be stored.

-   Go to the **Actions** tab in your repository.
-   Select the **`BUCKET - Bootstrap`** workflow.
-   Click **`Run workflow`**.

### **Step 2: Create the Database Storage Volume** 💾

This workflow creates or imports the persistent block volume for the database.

-   Go to the **Actions** tab.
-   Select the **`STORAGE - Create / Import`** workflow.
-   Click **`Run workflow`**.
    -   If you have an existing volume, provide its OCID in the `import_ocid` input field.
    -   Otherwise, leave the inputs as default to create a new 50GB volume.
-   After the workflow succeeds, copy the `db_storage_ocid` from the output logs.
-   **Important**: Go back to your repository secrets and add/update the `DB_STORAGE_OCID` secret with this value. This links the main stack to the volume.

### **Step 3: Plan and Apply the Main Stack** 🏗️

This provisions all the networking, compute, and Kubernetes resources.

1.  **Plan (Optional but Recommended)**: The **`STACK - Plan`** workflow is automatically triggered on pushes to `main`. You can also run it manually to review the changes Terraform will make.
2.  **Apply**:
    -   Go to the **Actions** tab.
    -   Select the **`STACK - Apply`** workflow.
    -   Click **`Run workflow`**.

This will take several minutes to complete. Once finished, your K3s cluster is up and running!

### **Step 4: Accessing the Cluster** 💻

-   Find the bastion's public IP in the output of the `STACK - Apply` workflow run.
-   SSH into the bastion: `ssh opc@<BASTION_PUBLIC_IP>`
-   From the bastion, you can SSH into any of the private cluster nodes.
-   The Argo CD admin password and PostgreSQL password are saved on the control plane node at `/home/opc/credentials.txt`.

---

## 💣 How to Destroy

To tear down all resources, run the workflows in the reverse order of creation.

1.  **Destroy the Main Stack**: Run the **`STACK - Destroy`** workflow. This will remove all compute instances, network components, and load balancers.
2.  **Destroy the Storage Volume**: Run the **`STORAGE - Destroy`** workflow. **Warning**: This is a destructive action and will permanently delete the block volume and all data on it.
3.  **Delete the Bucket (Manual)**: The bootstrap workflow does not destroy the state bucket for safety. You must delete it manually from the OCI console if desired.

---

## 📂 Repository Structure

```bash
infra-newsapp/
├── .github/workflows/   # GitHub Actions for CI/CD
├── modules/               # Reusable Terraform modules
│   ├── cluster/         # K3s nodes, bastion, LB backends
│   ├── network/         # VCN, subnets, NSGs, LBs, DNS
│   └── storage/         # OCI Block Volume
├── scripts/               # Cloud-init shell scripts for node setup
│   ├── k3s-install-agent.sh
│   └── k3s-install-server.sh
└── terraform/             # Terraform root configurations (workspaces)
├── 0-bootstrap/     # Creates the TF state bucket
├── 1-storage/       # Manages the DB block volume
└── 2-stack/         # The main infrastructure stack
```

<br/>
<details>
<summary>📋 <b>Available GitHub Actions Workflows</b></summary>

-   **`BUCKET - Bootstrap`**: Creates the OCI bucket for Terraform state. Run this first.
-   **`STORAGE - Create / Import`**: Creates or imports the persistent block volume. Run this second.
-   **`STORAGE - Destroy`**: Destroys the block volume.
-   **`STACK - Plan`**: Runs `terraform plan` on the main stack. Triggers on push to `main`.
-   **`STACK - Apply`**: Applies the main stack configuration to build the cluster.
-   **`STACK - Destroy`**: Destroys the main stack infrastructure.
-   **`STACK - Diagnostics`**: A utility to test OCI credentials and discover availability domains.
-   **`STACK - Validate CIDRs`**: A validation check to ensure `ADMIN_CIDRS` and `CLOUDFLARE_CIDRS` secrets are correctly formatted.
-   **`STACK - Test Remote State`**: A quick utility to verify that Terraform can authenticate and write to the remote state bucket.
-   **`STORAGE - Migrate Storage State`**: A utility workflow to move a volume resource from the main state file to a separate storage state file.
</details>














---

## 🧩 Application Configuration

The infrastructure is designed to run the `newsApp` application, which is deployed via Argo CD from the following source repositories:
-   **Frontend**: `https://github.com/ghGill/newsAppFront`
-   **Backend**: `https://github.com/ghGill/newsAppbackend`

The following environment variables are required by the application itself. These are **not** Terraform variables; they should be managed as Kubernetes secrets (ideally using the provisioned Sealed Secrets controller) and applied to your deployments.

### **Frontend Environment Variables**

#### Build-Time (Vite)

| Variable                      | Description                               | Example                                  |
| ----------------------------- | ----------------------------------------- | ---------------------------------------- |
| `VITE_SERVER_URL`             | The base path for API requests.           | `/api`                                   |
| `VITE_NEWS_INTERVAL_IN_MIN`   | The interval in minutes to fetch news.    | `5`                                      |
| `VITE_FRONTEND_GIT_BRANCH`    | Git branch of the frontend build.         | `main`                                   |
| `VITE_FRONTEND_GIT_COMMIT`    | Git commit SHA of the frontend build.     | `a1b2c3d`                                |

#### Runtime (NGINX)

| Variable                   | Description                                             | Example                                  |
| -------------------------- | ------------------------------------------------------- | ---------------------------------------- |
| `BACKEND_SERVICE_HOST`     | The internal Kubernetes service hostname for the backend. | `backend.default.svc.cluster.local`      |
| `BACKEND_SERVICE_PORT`     | The port of the backend service.                        | `8080`                                   |

### **Backend Environment Variables**

#### Database Configuration

| Variable         | Description                                                        | Example      |
| ---------------- | ------------------------------------------------------------------ | ------------ |
| `DB_ENGINE_TYPE` | The database engine type (`POSTGRES`, `MONGO`, etc.).              | `POSTGRES`   |
| `DB_PROTOCOL`    | The database connection protocol.                                  | `postgresql` |
| `DB_USER`        | The database username.                                             | `news_user`  |
| `DB_PASSWORD`    | The database password. **(Should be a secret)** | `s3cr3t_p4ss`|
| `DB_HOST`        | The internal Kubernetes service hostname for the database.         | `postgresql-prod-client.default.svc.cluster.local` |
| `DB_PORT`        | The port for the database service.                                 | `5432`       |
| `DB_NAME`        | The name of the database.                                          | `newsdb_prod`|

#### Storage Configuration

| Variable                | Description                                                                                                   | Example                      |
| ----------------------- | ------------------------------------------------------------------------------------------------------------- | ---------------------------- |
| `STORAGE_TYPE`          | The storage backend type (`AWS_S3` or `DISK`).                                                                | `AWS_S3`                     |
| `AWS_ACCESS_KEY_ID`     | AWS Access Key ID. **(Required if `STORAGE_TYPE` is `AWS_S3`)** | `AKIA...`                    |
| `AWS_SECRET_ACCESS_KEY` | AWS Secret Access Key. **(Required if `STORAGE_TYPE` is `AWS_S3`; should be a secret)** | `wJal...`                    |
| `AWS_REGION`            | The AWS region for the S3 bucket. **(Required if `STORAGE_TYPE` is `AWS_S3`)** | `us-east-1`                  |
| `AWS_BUCKET`            | The name of the S3 bucket. **(Required if `STORAGE_TYPE` is `AWS_S3`)** | `my-app-data-bucket`         |
| `DISK_ROOT_PATH`        | The root path on the disk for local storage. **(Required if `STORAGE_TYPE` is `DISK`)** | `/data/movies`               |

#### Build Information

| Variable             | Description                              | Example   |
| -------------------- | ---------------------------------------- | --------- |
| `BACKEND_GIT_BRANCH` | Git branch of the backend build.         | `main`    |
| `BACKEND_GIT