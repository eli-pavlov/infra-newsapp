
# === Storage module variables ===
variable "oci_tenancy_ocid" {
  description = "OCID of the OCI tenancy (used by the OCI provider)."
  type        = string
  sensitive   = false
}

variable "oci_user_ocid" {
  description = "OCID of the OCI user (used by the OCI provider)."
  type        = string
  sensitive   = false
}

variable "oci_fingerprint" {
  description = "Fingerprint for the OCI API key (used by the OCI provider)."
  type        = string
  sensitive   = false
}

variable "oci_private_key_pem" {
  description = "PEM private key for the OCI API user. Provide the full PEM contents (sensitive)."
  type        = string
  sensitive   = true
}

variable "oci_region" {
  description = "OCI region (e.g. eu-frankfurt-1)."
  type        = string
  sensitive   = false
}

variable "compartment_ocid" {
  description = "OCID of the compartment where resources will be created."
  type        = string
  sensitive   = false
}

variable "availability_domain" {
  description = "Availability Domain for resources (used by block storage creation)."
  type        = string
  sensitive   = false
}

variable "os_namespace" {
  description = "Object Storage namespace (used for Terraform backend)."
  type        = string
  sensitive   = false
}

variable "tf_state_bucket" {
  description = "Name of the Object Storage bucket used to store Terraform state files."
  type        = string
  sensitive   = false
}

variable "tf_state_key" {
  description = "Path/key (inside the bucket) for the root Terraform state file (e.g. states/root.state)."
  type        = string
  sensitive   = false
}

variable "storage_state_key" {
  description = "Path/key (inside the bucket) for the storage Terraform state file (e.g. states/storage.state)."
  type        = string
  default     = "states/storage.state"
  sensitive   = false
}

variable "db_storage_ocid" {
  description = "OCID of the DB block storage (when adopting an existing volume). Set from repo secret DB_STORAGE_OCID."
  type        = string
  sensitive   = false
}

variable "volume_size_gb" {
  description = "Desired size (GB) for the DB block volume when creating it."
  type        = number
  default     = 50
  sensitive   = false
}

variable "storage_display_name" {
  description = "Human-friendly display name for the DB block volume."
  type        = string
  default     = "newsapp-db-volume"
  sensitive   = false
}
