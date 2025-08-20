variable "region" { type = string }
variable "compartment_ocid" { type = string }

variable "vcn_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  type    = string
  default = "10.0.2.0/24"
}

variable "admin_cidrs" {
  type        = list(string)
  description = "Admin/public IP CIDRs (SSH to bastion etc)."
}

variable "cloudflare_cidrs" {
  type        = list(string)
  description = "Cloudflare IP ranges allowed to reach 80/443 on the public NLB."
}
