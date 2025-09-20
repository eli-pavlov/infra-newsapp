
# Output: OCID of the created database storage volume
output "db_storage_ocid" {
  value = oci_core_volume.db_volume.id
}