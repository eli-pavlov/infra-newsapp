# modules/cluster/variables.tf

variable "region" { type = string }
variable "availability_domain" { type = string }
variable "compartment_ocid" { type = string }
variable "cluster_name" { type = string }

variable "os_image_id" {
  description = "The OCID of the OS image for the K8s nodes (control plane and workers)."
  type        = string
}

variable "bastion_os_image_id" {
  description = "The OCID of the OS image specifically for the bastion host."
  type        = string
}

variable "public_key_content" {
  description = "The content of the public SSH key for the compute instances."
  type        = string
  sensitive   = true
}

variable "manifests_repo_url" {
  description = "The HTTPS URL of the Kubernetes manifests repository for Argo CD to clone."
  type        = string
}

# --- SHAPE AND RESOURCE VARIABLES ---
variable "node_shape" {
  description = "The base shape for all Kubernetes nodes. Must be a Flex shape."
  type        = string
  default     = "VM.Standard.A1.Flex"
}

variable "node_ocpus" {
  description = "The number of OCPUs to allocate to each Kubernetes node."
  type        = number
  default     = 1
}

variable "node_memory_gb" {
  description = "The amount of memory in GB to allocate to each Kubernetes node."
  type        = number
  default     = 6
}

# --- NETWORKING & NODE COUNT ---
variable "public_subnet_id"  { type = string }
variable "private_subnet_id" { type = string }

variable "bastion_nsg_id"       { type = string }
variable "control_plane_nsg_id" { type = string }
variable "workers_nsg_id"       { type = string }

variable "app_worker_count" {
  description = "Number of application worker nodes."
  type        = number
  default     = 2
}

# --- DATABASE & SECRET VARIABLES ---
variable "db_user" {
  description = "The username for the PostgreSQL database."
  type        = string
  default     = "news_user"
}

variable "db_name_dev" {
  description = "The database name for the development environment."
  type        = string
  default     = "newsdb_dev"
}

variable "db_name_prod" {
  description = "The database name for the production environment."
  type        = string
  default     = "newsdb_prod"
}

variable "db_service_name_dev" {
  description = "The Kubernetes service name for the dev database."
  type        = string
  default     = "postgresql-dev"
}

variable "db_service_name_prod" {
  description = "The Kubernetes service name for the prod database."
  type        = string
  default     = "postgresql-prod"
}

variable "db_volume_size_gb" {
  description = "The total size of the shared block volume for databases."
  type        = number
  default     = 50
}

# --- K3S VARIABLES ---
variable "k3s_version" {
  description = "The version of K3s to install."
  type        = string
  default     = "v1.33.4+k3s1"
}

variable "public_nlb_id" {
  description = "The OCID of the public Network Load Balancer."
  type        = string
}

variable "public_nlb_ip_address" {
  description = "The public IP address of the Network Load Balancer."
  type        = string
}

variable "private_lb_id" {
  description = "The OCID of the private Load Balancer for the Kube API."
  type        = string
}

variable "private_lb_ip_address" { type = string }

variable "public_nlb_backend_set_http_name" {
  description = "Name of the HTTP backend set on the public NLB."
  type        = string
}

variable "public_nlb_backend_set_https_name" {
  description = "Name of the HTTPS backend set on the public NLB."
  type        = string
}

variable "private_lb_backendset_name" {
  description = "Name of the backend set on the private classic LB for kube-apiserver."
  type        = string
}

# Cloudflare API token used by the instance user-data to create cert-manager secret
variable "cloudflare_api_token" {
  description = "Cloudflare API token (sensitive). Passed into instance user-data to create cert-manager secret."
  type        = string
  sensitive   = true
  default     = ""
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

# sealed-secrets keypair (base64-encoded)
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

variable "db_storage_ocid" {
  description = "OCID of the DB block storage volume (provided by root via remote state or secret fallback)."
  type        = string
  sensitive   = false
  default     = ""
}