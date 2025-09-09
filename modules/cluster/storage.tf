# Use the SAME AD as your DB worker node
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

locals {
  db_ad_name = data.oci_identity_availability_domains.ads.availability_domains[var.db_ad_index].name
}

resource "oci_core_volume" "shared_db_volume" {
  availability_domain = local.db_ad_name
  compartment_id      = var.compartment_ocid
  display_name        = "db-paravirt-volume"

  # numbers, not strings:
  size_in_gbs  = var.db_volume_size_gb     # e.g., 20
  vpus_per_gb  = 10                        # 0=LowerCost, 10=Balanced, 20/30=HigherPerf
}

resource "oci_core_volume_attachment" "db_attach" {
  compartment_id = var.compartment_ocid
  instance_id    = oci_core_instance.db_worker.id      # your DB node resource
  volume_id      = oci_core_volume.shared_db_volume.id

  type  = "paravirtualized"
  # optional: leave device blank and let OS pick /dev/oracleoci/oraclevdb
  display_name = "db-paravirt-attach"
}
