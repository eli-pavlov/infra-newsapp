variable "tenancy_ocid" {
  type      = string
  sensitive = true
}

variable "admin_cidr" {
  type    = string
  default = null
}

variable "os_image_id" {
  type    = string
  default = null
}

variable "cluster_name" {
  type    = string
  default = null
}

variable "bucket_name" {
  type    = string
  default = null
}

variable "os_namespace" {
  type    = string
  default = null
}