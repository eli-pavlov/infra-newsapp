terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.18.0"
    }
  }
}

provider "oci" {
  tenancy_ocid     = var.oci_tenancy_ocid
  user_ocid        = var.oci_user_ocid
  fingerprint      = var.oci_fingerprint
  private_key_pem  = var.oci_private_key_pem
  region           = var.oci_region
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}