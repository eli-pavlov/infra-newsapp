
# === Backend configuration ===
# This empty block tells Terraform to expect backend configuration
# for OCI during the 'init' command. The actual connection details
# (bucket, key, etc.) will be provided by the workflow.
terraform {
  backend "oci" {}
}