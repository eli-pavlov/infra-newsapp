# infra/storage/main.tf
module "storage" {
  source = "../../modules/storage"
  availability_domain          = var.availability_domain
  compartment_ocid             = var.compartment_ocid
  volume_size_gb               = var.volume_size_gb
  storage_display_name         = var.storage_display_name
  oci_region                   = var.oci_region
  oci_private_key_pem          = var.oci_private_key_pem
  db_instance_ocid             = var.db_instance_ocid
  db_storage_ocid              = var.db_storage_ocid
  tf_state_bucket              = var.tf_state_bucket
  tf_state_key                 = var.tf_state_key
  os_namespace                 = var.os_namespace
  storage_state_key            = var.storage_state_key
  oci_tenancy_ocid             = var.oci_tenancy_ocid
  oci_fingerprint              = var.oci_fingerprint
  oci_user_ocid                = var.oci_user_ocid
}
