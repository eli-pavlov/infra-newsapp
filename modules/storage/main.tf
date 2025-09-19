terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.18.0"
    }
  }
}


provider "oci" {}

resource "oci_core_volume" "shared_db_volume" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "${var.cluster_name}-db-shared-volume"
  size_in_gbs         = var.volume_size_gb
}

variable "cluster_name" {
  description = "The name for the K3s cluster."
  type        = string
}
