variable "cluster_name" {
  description = "The name of the Kubernetes cluster."
  type        = string
}

variable "vcn_id" {
  description = "The OCID of the VCN to deploy the resources into."
  type        = string
}

variable "compartment_ocid" {
  description = "The OCID of the compartment where resources will be created."
  type        = string
}

variable "private_subnet_id" {
  description = "The OCID of the private subnet for the private load balancer."
  type        = string
}

variable "public_subnet_id" {
  description = "The OCID of the public subnet for the public network load balancer."
  type        = string
}

variable "workers_subnet_cidr" {
  description = "The CIDR block of the workers subnet."
  type        = string
}

variable "my_public_ip_cidr" {
  description = "The public IP CIDR of the admin machine for SSH access."
  type        = string
}