# modules/network/variables.tf

variable "region" {
  description = "The OCI region."
  type        = string
}

variable "compartment_ocid" {
  description = "The OCID of the compartment."
  type        = string
}

variable "vcn_cidr" {
  description = "CIDR for the entire VCN."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR for the public subnet."
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR for the private subnet."
  type        = string
  default     = "10.0.2.0/24"
}

variable "admin_cidrs" {
  description = "A list of admin IP CIDRs for SSH access."
  type        = list(string)
}

variable "cloudflare_cidrs" {
  description = "A list of Cloudflare IP CIDRs for load balancer access."
  type        = list(string)
}