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

# --- Variable Declarations ---

# The tenancy_ocid is a required argument that uniquely identifies
# your tenancy in OCI.
variable "tenancy_ocid" {
  type        = string
  description = "The OCID of the tenancy."
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

# The region is the geographical location where resources will be created.
variable "region" {
  type        = string
  description = "The OCI region to deploy resources into."
}

# --- Provider Configuration ---

# Configure the OCI provider. The values for these arguments are
# automatically passed in from the GitHub Actions workflow environment
# variables, which are prefixed with `TF_VAR_`.
provider "oci" {
  # The tenancy_ocid is a required argument that uniquely identifies
  # your tenancy in OCI. It's set from the `tenancy_ocid` variable.
  user_ocid = var.user_ocid
  # The fingerprint corresponds to the fingerprint of the public key
  # associated with the user. It's set from the `fingerprint` variable.
  fingerprint = var.fingerprint
  # The private_key_path tells the OCI provider where to find the private key
  # file on the runner. This is the key that was written from the secret.
  # It's set from the `private_key_path` variable.
  private_key_path = var.private_key_path
  # The region is the geographical location where resources will be created.
  # It's set from the `region` variable.
}
