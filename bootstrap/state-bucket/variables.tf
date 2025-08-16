variable "region" {
  description = "OCI region, e.g., eu-frankfurt-1"
  type        = string
}

variable "tenancy_ocid" {
  description = "Tenancy OCID"
  type        = string
  sensitive   = true
}

variable "user_ocid" {
  description = "User OCID"
  type        = string
  sensitive   = true
}

variable "fingerprint" {
  description = "API key fingerprint"
  type        = string
  sensitive   = true
}

variable "private_key_path" {
  description = "Path to the PEM private key on the runner/host"
  type        = string
}

# Uncomment if your key is passphrase-protected
# variable "private_key_password" {
#   description = "Passphrase for the private key"
#   type        = string
#   sensitive   = true
# }
