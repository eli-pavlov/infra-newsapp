NEEDED ENV VARS

newsapp-infra — Infrastructure & GitHub Actions (OCI + Terraform) 🚀

Single-repo overview for the Terraform modules & GitHub Actions that bootstrap and manage the newsapp infrastructure on Oracle Cloud (OCI).
Clear, minimal, copy-paste friendly README — all raw markdown in one window.

Table of contents

What this repo does

Quick links / Workflows

Getting started (local / CI)

Required repository secrets & envs (short)

Repo layout (high level)

Modules overview

Common tasks & examples

Troubleshooting checklist

Security notes

Contributing & support

License

What this repo does

Provides Terraform modules and workspaces to create a K3s cluster (1 control-plane + workers), networking, load-balancers, bastion, and storage on OCI.

Uses GitHub Actions workflows to:

bootstrap an OCI object storage bucket for Terraform state

plan / apply the infra stack

run diagnostics and state tests

create/destroy/manage block storage for DB

validate CIDR & Cloudflare inputs

Boots cluster with user-data scripts that install K3s, helm, ArgoCD, sealed-secrets and prepare volumes.

Quick links / Workflows 🔧

/.github/workflows contains the main CI orchestration:

Bucket - bootstrap.yml — create the TF state bucket (manual dispatch).

Stack - plan.yml — run terraform plan (on push to branches / manual).

Stack - apply.yml — run terraform apply (manual dispatch, environment=production).

Stack - diagnostics.yml — run OCI & Terraform diagnostics (manual).

Stack - test state.yml — test remote-state creation (manual).

Stack - validate cidrs.yml — validate JSON CIDR secrets (manual / on push).

Stack- destroy.yml — full terraform destroy (manual).

Storage - create.yml / Storage - destroy.yml / Storage - migrate storage state.yml — storage workspace lifecycle.

Pro tip: trigger workflows manually from Actions UI or with gh CLI:

# Example (needs gh authenticated and repo context)
gh workflow run "Stack - Plan" --repo OWNER/REPO

Getting started (local / CI) ⚡
1) Prepare GitHub repository secrets

This repo expects a number of secrets (short list below). Set these in Settings → Secrets & variables → Actions.

2) Bootstrap state (create the bucket)

Trigger Bucket - bootstrap workflow (manually in Actions).

Or run Terraform locally:

cd terraform/0-bootstrap
export TF_VAR_compartment_ocid="ocid1.compartment..."
export TF_VAR_tenancy_ocid="..."
export TF_VAR_user_ocid="..."
export TF_VAR_fingerprint="..."
export TF_VAR_private_key_pem="$(cat ~/.oci/oci_api_key.pem)"
export TF_VAR_region="eu-frankfurt-1"
export TF_VAR_bucket_name="your-tf-state-bucket"
export TF_VAR_os_namespace="your-oci-namespace"

terraform init -upgrade
terraform apply -auto-approve

3) Stack plan & apply

Workflows call terraform init -backend-config=... with the bucket+key+namespace. If running locally, mirror that:

cd terraform/2-stack
terraform init \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=${TF_STATE_KEY}" \
  -backend-config="namespace=${OS_NAMESPACE}" \
  -backend-config="region=${OCI_REGION}"

terraform validate
terraform plan -out=tfplan
terraform apply -auto-approve -input=false tfplan

Required repository secrets & envs (short)

These are the most important secrets used across the workflows. Keep them in GitHub Secrets.

OCI_TENANCY_OCID — tenancy OCID (string)

OCI_USER_OCID — user OCID

OCI_FINGERPRINT — key fingerprint

OCI_PRIVATE_KEY_PEM — private key contents (PEM)

OCI_REGION — e.g. eu-frankfurt-1

COMPARTMENT_OCID — target compartment OCID

TF_STATE_BUCKET — Object Storage bucket name (for Terraform states)

OS_NAMESPACE — OCI object storage namespace

TF_STATE_KEY — root state key (e.g. newsapp.tfstate)

AVAILABILITY_DOMAIN — AD string used for block storage

OS_IMAGE_ID, BASTION_IMAGE — image OCIDs used by provisioning

AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION, AWS_BUCKET — optional S3 credentials for app storage

CLOUDFLARE_API_TOKEN, CLOUDFLARE_ZONE_ID — Cloudflare integration

ADMIN_CIDRS, CLOUDFLARE_CIDRS — JSON arrays (strings) of CIDRs — used by validation workflow

STORAGE_TYPE — e.g. s3 or disk

DB_STORAGE_OCID — optional: existing block volume OCID if importing

SEALED_SECRETS_CERT, SEALED_SECRETS_KEY — base64-encoded sealed-secrets TLS creds

See the workflows for additional variables — they pass many TF_VAR_* from secrets.

Repo layout (high level)
.
├─ .github/workflows/        # main GitHub Actions workflows (bootstrap, plan, apply, storage, diagnostics)
├─ modules/
│  ├─ cluster/               # K3s cluster module (instances, cloud-init, PV attach)
│  ├─ network/               # VCN, subnets, load balancers, DNS, NSGs
│  ├─ storage/               # block volume creation & outputs
├─ terraform/
│  ├─ 0-bootstrap/           # terraform to create TF state bucket
│  ├─ 1-storage/             # storage workspace
│  └─ 2-stack/               # main infra stack (uses modules and remote state)
├─ scripts/                  # cloud-init scripts (k3s server + agent)
├─ .gitignore
└─ README.md                 # (you are here)

Modules overview 🧩
modules/network

Creates VCN, public/private subnets, internet & NAT gateways.

Sets up public Network Load Balancer (NLB) for ingress -> NodePorts (30080/30443).

Creates private classic LB for Kube API (6443).

Manages Cloudflare DNS records and ruleset for argocd & newsapp hosts.

Outputs NLB IDs / IPs and NSG IDs for cluster module.

modules/cluster

Creates compute instances: control-plane, app workers, db worker, bastion.

Uses cloudinit_config templates to provision K3s, Helm, ArgoCD, Sealed-Secrets.

Attaches DB block volume via oci_core_volume_attachment (volume created by storage module or imported).

modules/storage

Creates OCI block volume for DB (when requested).

Designed to be operated in a separate Terraform workspace/state file (see Storage - create.yml).

Common tasks & examples
Trigger a workflow (manual dispatch)

From the Actions UI or:

# Using gh (GitHub CLI)
gh workflow run "Bucket - bootstrap" --repo OWNER/REPO

Inspect Terraform plan artifacts uploaded by workflows

Workflows upload tfplan, plan-meta.json as artifacts — download from Actions → run logs → Artifacts.

Decode the SSH public key stored as object

Workflows expect oracle.key.pub present in object storage — the cluster module reads it (used as public_key_content).

Migrate storage volume into separate state

Use Storage - migrate storage state workflow (manual) — it:

Removes the volume resource from the main state.

Initializes infra/storage workspace and imports the OCID (if available).

Verifies the storage state.

Troubleshooting checklist 🔍

If a workflow fails with Invalid provider configuration or Terraform errors:

Secrets missing — the workflows guard early; check Actions logs for the "required secrets are missing" message.

OCI private key format — ensure OCI_PRIVATE_KEY_PEM contains exact PEM content with -----BEGIN PRIVATE KEY----- and line breaks preserved.

TF backend config mismatch — confirm TF_STATE_BUCKET, TF_STATE_KEY, OS_NAMESPACE match values used during terraform init.

Provider version mismatches — workflows set terraform_version: 1.13.1 and provider constraints in providers.tf. If running locally, use same Terraform & provider plugin versions or run terraform init -upgrade carefully.

Sealed-Secrets decode errors — ensure SEALED_SECRETS_CERT / KEY are base64-encoded; workflows decode them and apply as TLS secret in kube-system.

Cloudflare rules / DNS — if clients can't reach services, check Cloudflare proxied vs DNS only and cloudflare_cidrs used for NSG rules.

NLB health checks failing — ensure NodePorts (30080/30443) are open in NSGs and the ingress controller is running on those NodePorts.

Security notes 🔐

Never commit .tfvars containing secrets. .gitignore already excludes *.tfvars and *.pem.

Store private keys and secrets in GitHub Actions Secrets (encrypted).

terraform state in OCI bucket contains sensitive values — bucket should be private and versioning enabled (workflow sets versioning = "Enabled").

Sealed-Secrets certs/keys are used to encrypt Kubernetes secrets; protect those base64 strings carefully.

Contributing & support 🤝

Open issues for bugs / misunderstandings.

Prefer small PRs that change a single workflow or module.

When changing TF provider versions, update .terraform.lock.hcl via terraform init -upgrade locally and include the lockfile in PR.

Quick reference (cheat sheet)

Bootstrap TF state bucket: Bucket - bootstrap (Actions)

Plan: Stack - plan.yml

Apply: Stack - apply.yml (manual, environment=production)

Storage create/import: Storage - create.yml

Validate CIDRs: Stack - validate cidrs.yml

Destroy infra: Stack- destroy.yml (manual, careful)

License

This repository contains infrastructure code. Add your preferred license file (e.g., LICENSE). If you're unsure, consider MIT for permissive open-source usage.


# --- App Source Repos ---
https://github.com/ghGill/newsAppFront
https://github.com/ghGill/newsAppbackend

# --- Frontend build-time (Vite) ---
VITE_SERVER_URL={{VITE_SERVER_URL}}                    # e.g. /api
VITE_NEWS_INTERVAL_IN_MIN={{VITE_NEWS_INTERVAL_IN_MIN}}  # e.g. 5

# --- Frontend runtime (Nginx proxy target) ---
BACKEND_SERVICE_HOST={{BACKEND_SERVICE_HOST}}          # e.g. backend.default.svc.cluster.local
BACKEND_SERVICE_PORT={{BACKEND_SERVICE_PORT}}          # e.g. 8080

# --- Backend DB config (example) ---
# MONGO | MONGOOSE | POSTGRES | MYSQL
DB_ENGINE_TYPE={{DB_ENGINE_TYPE}}
# connection string : [protocol]://[username]:[password]@[host]:[port]/[database]
DB_PROTOCOL= ( required, without :// )
DB_USER= ( can be empty, optional )
DB_PASSWORD= ( can be empty, optional )
DB_HOST= ( required )
DB_PORT= ( can be empty, optional ) 
DB_NAME= ( required )

# AWS_S3 | DISK
STORAGE_TYPE=

# In case of STORAGE_TYPE = AWS_S3
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_REGION=
AWS_BUCKET= [ the name of the bucket where to create the movies folder ]

# In case of STORAGE_TYPE = DISK
DISK_ROOT_PATH= [ full path on disk to the root directory where to create the movies folder ]

# Frontend commit info
VITE_FRONTEND_GIT_BRANCH=
VITE_FRONTEND_GIT_COMMIT=
# Backedn commit info
BACKEND_GIT_BRANCH=
BACKEND_GIT_COMMIT