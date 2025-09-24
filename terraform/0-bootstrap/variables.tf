variable "tenancy_ocid" {
  type      = string
  sensitive = true
}

variable "user_ocid" {
  type      = string
  sensitive = true
}

variable "fingerprint" {
  type      = string
  sensitive = true
}

variable "private_key_pem" {
  type      = string
  sensitive = true
}

variable "region" {
  type      = string
  sensitive = true
}

variable "compartment_ocid" {
  type      = string
  sensitive = true
}

variable "bucket_name" {
  type      = string
  sensitive = true
}

variable "os_namespace" {
  type      = string
  sensitive = true
}