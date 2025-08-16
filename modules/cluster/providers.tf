# This file configures the OCI provider for Terraform to use with your
# OCI account and the credentials provided by the GitHub Actions secrets.

# Define the required providers. This ensures that Terraform knows to
# download and use the correct provider plugins.
terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 5.0"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.3"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}
