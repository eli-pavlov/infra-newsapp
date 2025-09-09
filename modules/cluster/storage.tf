resource "oci_core_volume" "shared_db_volume" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "${var.cluster_name}-db-shared-volume"
  size_in_gbs         = var.db_volume_size_gb
}

resource "oci_core_volume_attachment" "db_volume_attachment" {
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.db_worker.id
  volume_id       = oci_core_volume.shared_db_volume.id
  display_name    = "${var.cluster_name}-db-attachment"
}