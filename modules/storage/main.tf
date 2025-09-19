# modules/storage/main.tf
terraform {
  required_providers {
    oci = { source = "hashicorp/oci" }
  }
}

provider "oci" {}

resource "oci_core_volume" "storage" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_id
  display_name        = var.display_name
  size_in_gbs         = var.volume_size_gb
  # add other args if needed
}
