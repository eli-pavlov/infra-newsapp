resource "oci_core_volume" "db" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_ocid
  size_in_gbs         = var.db_volume_size_gb
  display_name        = "k3s-db-volume"
}

resource "oci_core_volume_attachment" "db_to_server0" {
  compartment_id  = var.compartment_ocid
  instance_id     = oci_core_instance.k3s_servers[0].id  # <-- adjust if your instance resource name differs
  volume_id       = oci_core_volume.db.id
  attachment_type = "paravirtualized"
  device          = var.db_volume_device
}
