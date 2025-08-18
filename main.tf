terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.3"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

module "network" {
  source            = "./modules/network"
  region            = var.region
  compartment_ocid  = var.compartment_ocid
  tenancy_ocid      = var.tenancy_ocid
  my_public_ip_cidr = var.admin_cidr
}

module "cluster" {
  source                   = "./modules/cluster"
  region                   = var.region
  availability_domain      = var.availability_domain
  compartment_ocid         = var.compartment_ocid
  cluster_name             = var.cluster_name
  public_key_content       = var.public_key_content
  os_image_id              = var.os_image_id
  public_nlb_id            = module.network.public_nlb_id
  public_nlb_ip_address    = module.network.public_nlb_ip_address
  private_lb_id            = module.network.private_lb_id
  private_lb_ip_address    = module.network.private_lb_ip_address
  workers_subnet_id        = module.network.workers_subnet_id
  workers_http_nsg_id      = module.network.private_lb_security_group
  servers_kubeapi_nsg_id   = module.network.public_nlb_security_group
}

