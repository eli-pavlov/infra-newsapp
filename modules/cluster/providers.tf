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

# Configure the OCI provider. The values for these arguments are
# automatically passed in from the GitHub Actions workflow environment
# variables, which are prefixed with `TF_VAR_`.
provider "oci" {
  # The tenancy_ocid is a required argument that uniquely identifies
  # your tenancy in OCI.
  tenancy_ocid     = var.tenancy_ocid
  # The user_ocid is a required argument that identifies the user account
  # that Terraform will use for authentication.
  user_ocid        = var.user_ocid
  # The fingerprint corresponds to the fingerprint of the public key
  # associated with the user.
  fingerprint      = var.fingerprint
  # The private_key_path tells the OCI provider where to find the private key
  # file on the runner. This is the key that was written from the secret.
  private_key_path = var.private_key_path
  # The region is the geographical location where resources will be created.
  region           = var.region
}