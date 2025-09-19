# modules/cluster/storage.tf  (AFTER)
# The block storage resource is now managed by infra/storage (separate workspace & state).
# This module no longer creates or destroys the volume. The stack reads the existing volume
# by OCID using data.oci_core_volume.db_volume (defined in root main.tf).
# (Volume creation / lifecycle is handled by infra/storage)

resource "oci_core_volume_attachment" "db_volume_attachment" {
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.db_worker.id
  volume_id   = data.oci_core_volume.db_volume.id
  display_name    = "${var.cluster_name}-db-attachment"
}