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

variable "public_key_content" {
  description = "The content of the public SSH key for the compute instances."
  type        = string
  sensitive   = true
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