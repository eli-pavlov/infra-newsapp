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


# The user_ocid is a required argument that identifies the user account
# that Terraform will use for authentication.
variable "user_ocid" {
  type        = string
  description = "The OCID of the user."
}

# The fingerprint corresponds to the fingerprint of the public key
# associated with the user.
variable "fingerprint" {
  type        = string
  description = "The fingerprint of the user's public key."
}

# The private_key_path tells the OCI provider where to find the private key
# file on the runner. This is the key that was written from the secret.
variable "private_key_path" {
  type        = string
  description = "The path to the OCI private key file on the runner."
}

provider "oci" {
  tenancy_ocid    = var.tenancy_ocid
  user_ocid       = var.user_ocid
  fingerprint     = var.fingerprint
  private_key_pem = var.private_key_pem
  region          = var.region
}