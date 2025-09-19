terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.18.0"
    }
  }
}

provider "oci" {
  tenancy_ocid = var.tenancy_ocid
  user_ocid    = var.user_ocid
  fingerprint  = var.fingerprint
  region       = var.region
  private_key  = var.private_key_pem
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}