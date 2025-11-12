
# === Cluster module: storage attachment ===
# The block storage resource is now managed by infra/storage (separate workspace & state).
# This module no longer creates or destroys the volume. The stack reads the existing volume
# by OCID using data.oci_core_volume.db_volume (defined in root main.tf).
# (Volume creation / lifecycle is handled by infra/storage)

# === Cluster module: storage attachment (OPTIONAL) ===
# Attaches an existing OCI block volume to the DB worker if an OCID is provided.
# If no OCID is supplied (empty string), the attachment is skipped so the stack
# can still come up and the software layer can fall back to local-path/ephemeral.

locals {
  has_db_volume = var.db_storage_ocid != null && var.db_storage_ocid != ""
}
resource "oci_core_volume_attachment" "db_volume_attachment" {
  count           = local.has_db_volume ? 1 : 0
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.db_worker.id
  volume_id       = var.db_storage_ocid
  display_name    = "${var.cluster_name}-db-attachment"
}

