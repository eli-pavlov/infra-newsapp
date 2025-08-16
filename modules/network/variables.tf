variable "region" {
  type = string
}

variable "tenancy_ocid" {
  type = string
}

variable "compartment_ocid" {
  type = string
}

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

variable "my_public_ip_cidr" {
  type        = string
  description = "My public ip CIDR"
}

variable "cluster_name" {
  description = "The name of the Kubernetes cluster."
  type        = string
}

variable "vcn_id" {
  description = "The OCID of the VCN to deploy the load balancer into."
  type        = string
}

variable "private_subnet_id" {
  description = "The OCID of the private subnet to use for the load balancer."
  type        = string
}

variable "availability_domain_name" {
  description = "The name of the availability domain to place the load balancer in."
  type        = string
}