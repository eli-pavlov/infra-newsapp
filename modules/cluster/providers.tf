
# === Cluster module provider configuration ===
# Sources only — version constraints live in the root module (terraform/2-stack).
terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
    random = {
      source = "hashicorp/random"
    }
    cloudinit = {
      source = "hashicorp/cloudinit"
    }
  }
}
