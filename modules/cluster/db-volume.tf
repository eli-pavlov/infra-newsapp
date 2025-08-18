resource "oci_core_volume" "db" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_ocid
  size_in_gbs         = var.db_volume_size_gb
  display_name        = "k3s-db-volume"
}

# Attach to the first server instance from the k3s_servers pool
resource "oci_core_volume_attachment" "db_to_first_server" {
  compartment_id  = var.compartment_ocid
  instance_id     = data.oci_core_instance_pool_instances.k3s_servers_instances.instances[0].id
  volume_id       = oci_core_volume.db.id
  attachment_type = "paravirtualized"
  device          = var.db_volume_device

  depends_on = [
    data.oci_core_instance_pool_instances.k3s_servers_instances
  ]
}
