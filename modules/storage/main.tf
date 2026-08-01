
# === Storage module main ===
terraform {
  required_providers {
    # Version constraint is intentionally left to the root module
    # (terraform/1-storage) so the two can never conflict.
    oci = {
      source = "oracle/oci"
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