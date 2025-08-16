variable "tenancy_ocid"       { type = string, sensitive = true }
variable "user_ocid"          { type = string, sensitive = true }
variable "fingerprint"        { type = string, sensitive = true }
variable "private_key_path"   { type = string, sensitive = true }
variable "region"             { type = string }

# From your env.auto.tfvars that triggered warnings:
variable "availability_domain" { type = string, default = null }
variable "admin_cidr"          { type = string, default = null }
variable "os_image_id"         { type = string, default = null }
variable "cluster_name"        { type = string, default = null }
variable "bucket_name"         { type = string, default = null }
variable "os_namespace"        { type = string, default = null }

# Anything your modules require will already be declared inside modules;
# add more top-level variables here only if Terraform complains again.
