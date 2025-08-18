# modules/cluster/db-volume.tf

resource "oci_core_volume" "db_volume" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_ocid
  size_in_gbs         = var.db_volume_size_gb
  display_name        = "${var.cluster_name}-db-volume"
}

# Attach the volume directly to the dedicated database worker node (node-3).
resource "oci_core_volume_attachment" "db_attachment" {
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.db_worker.id
  volume_id       = oci_core_volume.db_volume.id
  device          = var.db_volume_device # e.g., /dev/oracleoci/oraclevdb
}
