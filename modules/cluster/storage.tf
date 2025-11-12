# Optional: pull from remote state if you have it; 'try' avoids errors if it's absent.
# data "terraform_remote_state" "storage" { ... }  # (existing, if any)

locals {
  # Prefer var if set, else remote state, else empty. Trim whitespace.
  computed_db_storage_ocid = trimspace(
    try(coalesce(var.db_storage_ocid, data.terraform_remote_state.storage.outputs.db_volume_ocid), "")
  )
  attach_effective = var.attach_db_volume && local.computed_db_storage_ocid != ""
}

resource "oci_core_volume_attachment" "db_volume_attachment" {
  count           = local.attach_effective ? 1 : 0
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.db_worker.id
  volume_id       = local.computed_db_storage_ocid
  display_name    = "${var.cluster_name}-db-attachment"

  lifecycle {
    precondition {
      condition     = var.attach_db_volume ? (local.computed_db_storage_ocid != "") : true
      error_message = "attach_db_volume=true but db_storage_ocid is empty."
    }
  }
}
