
# === Provider configuration ===
terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 8.25"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.22"
    }
    # Used by null_resource.warn_db_storage_optional in main.tf; previously
    # relied on implicit installation, which left it unpinned.
    null = {
      source  = "hashicorp/null"
      version = "~> 3.3"
    }
  }
}

# OCI provider
provider "oci" {
  tenancy_ocid = var.tenancy_ocid
  user_ocid    = var.user_ocid
  fingerprint  = var.fingerprint
  region       = var.region
  private_key  = var.private_key_pem
}

# Cloudflare provider
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}