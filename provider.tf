provider "oci" {
  tenancy_ocid = var.tenancy_ocid
  user_ocid    = var.user_ocid
  fingerprint  = var.fingerprint
  region       = var.region
  
  # This line uses the private key content directly, as configured in the last steps.
  private_key  = var.private_key_pem 
}