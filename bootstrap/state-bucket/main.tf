# We pass the namespace from env/CI (no extra lookup)
# vars: compartment_ocid, bucket_name, os_namespace

data "oci_objectstorage_bucket_summaries" "list" {
  compartment_id = var.compartment_ocid
  namespace      = var.os_namespace
}

locals {
  bucket_summaries      = try(data.oci_objectstorage_bucket_summaries.list.bucket_summaries, [])
  exists_in_compartment = length([for b in local.bucket_summaries : b.name if b.name == var.bucket_name]) > 0
}

resource "oci_objectstorage_bucket" "state" {
  count          = local.exists_in_compartment ? 0 : 1
  compartment_id = var.compartment_ocid
  name           = var.bucket_name
  namespace      = var.os_namespace

  # Optional safety (uncomment if you want)
  # lifecycle { prevent_destroy = true }
}
