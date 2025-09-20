
# === Storage module main ===
terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.18.0"
    }
  }
}

# Block storage volume for database
resource "oci_core_volume" "db_volume" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = var.storage_display_name
  size_in_gbs         = var.volume_size_gb
}