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

variable "private_key_pem" {
  description = "The content of the OCI private key in PEM format."
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
  description = "The OCID of the base OS image for the compute instances."
  type        = string
}

variable "cluster_name" {
  description = "The name for the K3s cluster."
  type        = string
  default     = "news-app-cluster"
}

variable "public_key_content" {
  description = "The content of the public SSH key for the compute instances."
  type        = string
  sensitive   = true
}

variable "admin_cidrs" {
  description = "A list of personal/public CIDRs allowed to SSH to the bastion."
  type        = list(string)
}

variable "cloudflare_cidrs" {
  description = "A list of Cloudflare CIDRs allowed to reach the public load balancer."
  type        = list(string)
}

variable "tf_state_bucket" {
  description = "The name of the OCI Object Storage bucket for Terraform state and outputs."
  type        = string
}

variable "os_namespace" {
  description = "The OCI Object Storage namespace."
  type        = string
}

variable "manifests_repo_url" {
  description = "The HTTPS URL of the Git repository containing Kubernetes manifests for Argo CD."
  type        = string
}