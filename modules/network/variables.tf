variable "region" { type = string }
variable "tenancy_ocid" { type = string }
variable "compartment_ocid" { type = string }

variable "environment" {
  type    = string
  default = "staging"
}

variable "oci_core_vcn_dns_label" {
  type    = string
  default = "defaultvcn"
}

variable "oci_core_subnet_dns_label10" {
  type    = string
  default = "defaultsubnet10"
}

variable "oci_core_subnet_dns_label11" {
  type    = string
  default = "defaultsubnet11"
}

variable "oci_core_vcn_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "oci_core_subnet_cidr10" {
  type    = string
  default = "10.0.0.0/24"
}

variable "oci_core_subnet_cidr11" {
  type    = string
  default = "10.0.1.0/24"
}

# NEW: your personal IP ranges (SSH + kubeapi)
variable "admin_cidrs" {
  type        = list(string)
  description = "Admin/public IP CIDRs (SSH/ICMP to instances)."
}

# NEW: Cloudflare IP ranges (public site via 80/443)
variable "cloudflare_cidrs" {
  type        = list(string)
  description = "Cloudflare IP CIDRs allowed to reach the public NLB on ports 80/443."
}
