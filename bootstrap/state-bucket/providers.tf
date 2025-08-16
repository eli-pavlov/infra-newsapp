# bootstrap/state-bucket/providers.tf
provider "oci" {
  region           = var.region
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
}
# bootstrap/state-bucket/variables.tf
variable "private_key_path" {
  description = "Path to the PEM private key on the runner/host"
  type        = string
}
