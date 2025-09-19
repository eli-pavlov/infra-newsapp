# variables.tf

variable "tenancy_ocid" {
  description = "The OCID of the tenancy."
  type        = string
  sensitive   = true
}

variable "user_ocid" {
  description = "The OCID of the user."
  type        = string
  sensitive   = true
}

variable "fingerprint" {
  description = "The fingerprint of the API key."
  type        = string
  sensitive   = true
}

variable "region" {
  description = "The OCI region to deploy resources in."
  type        = string
}

variable "compartment_ocid" {
  description = "The OCID of the compartment to deploy resources into."
  type        = string
}

variable "availability_domain" {
  description = "The availability domain for the cluster nodes."
  type        = string
}

variable "os_image_id" {
  description = "The OCID of the base OS image for the K8s compute instances."
  type        = string
}

variable "bastion_os_image_id" {
  description = "The OCID of the OS image specifically for the bastion host."
  type        = string
}

variable "cluster_name" {
  description = "The name for the K3s cluster."
  type        = string
}

variable "private_key_pem" {
  description = "The content of the OCI private key in PEM format."
  type        = string
  sensitive   = true
}

variable "admin_cidrs" {
  description = "Personal/public CIDRs allowed to SSH and reach kubeapi."
  type        = list(string)
}

variable "cloudflare_cidrs" {
  description = "Cloudflare CIDRs allowed to reach 80/443 on the public NLB."
  type        = list(string)
}

variable "os_namespace" {
  description = "Object Storage namespace (from OCI)."
  type        = string
  sensitive   = true
}

variable "tf_state_bucket" {
  description = "Object Storage bucket name where you also write infra outputs."
  type        = string
  sensitive   = true
}

variable "manifests_repo_url" {
  description = "Git URL of the Kubernetes manifests repo for Argo CD bootstrap."
  type        = string
  default     = "https://github.com/eli-pavlov/newsapp-manifests.git"
}
variable "argocd_host" {
  description = "Hostname for Argo CD (Cloudflare firewall target)."
  type        = string
  default     = "argocd.weblightenment.com"
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token used for DNS operations and cert-manager."
  type        = string
  sensitive   = true
  default     = ""
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID for the domain."
  type        = string
  sensitive   = true
}

# AWS S3 Bucket credentials for external storage of app data (e.g. Minio)
variable "aws_access_key_id" {
  description = "AWS Access Key ID for the S3 bucket."
  type        = string
  sensitive   = true
}

variable "aws_secret_access_key" {
  description = "AWS Secret Access Key for the S3 bucket."
  type        = string
  sensitive   = true
}

variable "aws_region" {
  description = "AWS Region for the S3 bucket."
  type        = string
  default     = "us-east-1"
}

variable "aws_bucket" {
  description = "Name of the S3 bucket for external storage."
  type        = string
}

variable "storage_type" {
  description = "Type of storage to use (e.g., 's3' for AWS S3)."
  type        = string
  default     = "s3"
}

variable "sealed_secrets_cert" {
  description = "Base64-encoded TLS certificate for Sealed Secrets controller."
  type        = string
  sensitive   = true
}

variable "sealed_secrets_key" {
  description = "Base64-encoded TLS private key for Sealed Secrets controller."
  type        = string
  sensitive   = true
}

variable "storage_state_key" {
  description = "Path/key (inside the bucket) for the storage Terraform state file (e.g. states/storage.state)."
  type        = string
  default     = "storage.tfstate"
  sensitive   = false
}

variable "db_storage_ocid" {
  description = "OCID of the DB block storage (optional fallback). Prefer reading from storage.state outputs."
  type        = string
  sensitive   = false
}
