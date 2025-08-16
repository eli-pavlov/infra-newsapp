terraform {
  required_providers {
    oci       = { source = "oracle/oci",      version = ">= 4.64.0" }
    cloudinit = { source = "hashicorp/cloudinit" }
    random    = { source = "hashicorp/random" }
  }
}
