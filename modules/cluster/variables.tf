# modules/cluster/variables.tf

variable "region" {
  type = string
}

variable "availability_domain" {
  type = string
}

variable "compartment_ocid" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "os_image_id" {
  type = string
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
  default     = "VM.Standard.A1.Flex" # OCI's ARM-based Free Tier eligible shape
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

variable "public_subnet_id" {
  type = string
}

variable "private_subnet_id" {
  type = string
}

variable "bastion_nsg_id" {
  type = string
}

variable "control_plane_nsg_id" {
  type = string
}

variable "workers_nsg_id" {
  type = string
}

variable "expected_total_node_count" {
  description = "The total number of nodes (control plane + all workers) expected in the cluster."
  type        = number
  default     = 4 # 1 master + 2 app + 1 db
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
  default     = 50 # OCI Free Tier includes 2 block volumes, totaling 200 GB.
}

# --- K3S VARIABLES ---

variable "k3s_version" {
  description = "The version of K3s to install."
  type        = string
  default     = "v1.28.8+k3s1"
}

variable "private_lb_ip_address" {
  type = string
}

variable "public_nlb_id" {
  description = "The OCID of the public Network Load Balancer."
  type        = string
}

variable "public_nlb_ip_address" {
  description = "The public IP address of the Network Load Balancer."
  type        = string
}

variable "ingress_controller_https_nodeport" {
  type    = number
  default = 30443
}

variable "private_lb_id" {
  description = "The OCID of the private Load Balancer for the Kube API."
  type        = string
}

variable "private_lb_ip_address" {
  type = string
}