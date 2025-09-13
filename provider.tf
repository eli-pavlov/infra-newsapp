terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.18.0"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.3"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.9.0"
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