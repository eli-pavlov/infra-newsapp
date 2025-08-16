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
  description = "The OCID of the base OS image for the compute instances."
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

variable "admin_cidr" {
  description = "The IP CIDR of the admin network to allow SSH access. Must be provided as a secret."
  type        = string
  # The default value has been removed to make this a required variable.
}

variable "private_key_pem" {
  description = "The content of the OCI private key in PEM format."
  type        = string
  sensitive   = true
}
