# === Cluster module: storage attachment (optional) ===
# With attach_db_volume=false or empty db_storage_ocid, we skip the attachment.
# The agent cloud-init handles local/ephemeral fallback.

locals {
  db_storage_ocid  = trimspace(var.db_storage_ocid)
  attach_effective = var.attach_db_volume && local.db_storage_ocid != ""
}

resource "oci_core_volume_attachment" "db_volume_attachment" {
  count           = local.attach_effective ? 1 : 0
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.db_worker.id
  volume_id       = local.db_storage_ocid
  display_name    = "${var.cluster_name}-db-attachment"

  lifecycle {
    precondition {
      condition     = var.attach_db_volume ? (local.db_storage_ocid != "") : true
      error_message = "attach_db_volume=true but db_storage_ocid is empty."
    }
  }
}
