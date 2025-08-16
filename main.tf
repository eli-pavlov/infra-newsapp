provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

module "network" {
  source            = "./modules/network"
  region            = var.region
  compartment_ocid  = var.compartment_ocid
  tenancy_ocid      = var.tenancy_ocid
  my_public_ip_cidr = local.resolved_admin_cidr
}

data "http" "ip" {
  url = "https://ifconfig.me/ip"
}

locals {
  # If admin_cidr is set, use it; otherwise use caller /32
  resolved_admin_cidr = var.admin_cidr != "" ? var.admin_cidr : "${data.http.ip.response_body}/32"
}
module "cluster" {
  source                 = "./modules/cluster"
  tenancy_ocid           = var.tenancy_ocid
  user_ocid              = var.user_ocid
  fingerprint            = var.fingerprint
  private_key_path       = var.private_key_path
  region                 = var.region
  availability_domain    = var.availability_domain
  compartment_ocid       = var.compartment_ocid
  cluster_name           = var.cluster_name
  public_key_path        = var.public_key_path
  os_image_id            = var.os_image_id
  public_nlb_id          = module.network.public_nlb_id
  public_nlb_ip_address  = module.network.public_nlb_ip_address
  private_lb_id          = module.network.private_lb_id
  private_lb_ip_address  = module.network.private_lb_ip_address
  workers_subnet_id      = module.network.workers_subnet_id
  workers_http_nsg_id    = module.network.private_lb_security_group
  servers_kubeapi_nsg_id = module.network.public_nlb_security_group
}

