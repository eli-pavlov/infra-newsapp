# === Cluster module: storage attachment ===
# The block storage volume is optional. When `var.db_storage_ocid` is empty,
# we skip attaching any volume and the DB node will fall back to local/ephemeral
# storage (handled in cloud-init).

locals {
  has_db_volume = var.db_storage_ocid != ""
}

resource "oci_core_volume_attachment" "db_volume_attachment" {
  count           = local.has_db_volume ? 1 : 0
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.db_worker.id
  volume_id       = var.db_storage_ocid
  display_name    = "${var.cluster_name}-db-attachment"
}
