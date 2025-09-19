terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.18.0"
    }
  }
}

resource "oci_core_volume" "db_volume" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = var.storage_display_name
  size_in_gbs         = var.volume_size_gb
}
# Also, remove the misplaced `variable "cluster_name"` from this file.

variable "cluster_name" {
  description = "The name for the K3s cluster."
  type        = string
}
