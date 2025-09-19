terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.18.0"
    }
  }
}


provider "oci" {}

resource "oci_core_volume" "storage" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = var.display_name
  size_in_gbs         = var.volume_size_gb
  # add other args if needed
}
