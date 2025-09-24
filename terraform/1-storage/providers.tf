terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.18.0" # Match the version used elsewhere for consistency
    }
  }
}

provider "oci" {
  tenancy_ocid = var.oci_tenancy_ocid
  user_ocid    = var.oci_user_ocid
  fingerprint  = var.oci_fingerprint
  region       = var.oci_region
  private_key  = var.oci_private_key_pem
}