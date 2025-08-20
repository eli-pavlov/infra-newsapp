# main.tf

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

provider "oci" {
  tenancy_ocid = var.tenancy_ocid
  user_ocid    = var.user_ocid
  fingerprint  = var.fingerprint
  region       = var.region
  private_key  = var.private_key_pem
}

module "network" {
  source           = "./modules/network"
  compartment_ocid = var.compartment_ocid
  region           = var.region
  admin_cidrs      = var.admin_cidrs
  cloudflare_cidrs = var.cloudflare_cidrs
}

module "cluster" {
  source = "./modules/cluster"

  region                = var.region
  availability_domain   = var.availability_domain
  compartment_ocid      = var.compartment_ocid
  cluster_name          = var.cluster_name
  public_key_content    = var.public_key_content
  os_image_id           = var.os_image_id
  bastion_os_image_id   = var.bastion_os_image_id
  manifests_repo_url    = var.manifests_repo_url

  # network wiring
  public_subnet_id      = module.network.public_subnet_id
  private_subnet_id     = module.network.private_subnet_id
  bastion_nsg_id        = module.network.bastion_nsg_id
  control_plane_nsg_id  = module.network.control_plane_nsg_id
  workers_nsg_id        = module.network.workers_nsg_id
  public_nlb_id         = module.network.public_nlb_id
  public_nlb_ip_address = module.network.public_nlb_ip_address
  private_lb_id         = module.network.private_lb_id
  private_lb_ip_address = module.network.private_lb_ip_address
}

# Optional: write a tiny JSON with a couple of useful outputs into your bucket
resource "oci_objectstorage_object" "infra_outputs" {
  namespace    = var.os_namespace
  bucket       = var.tf_state_bucket
  object       = "infrastructure-outputs.json"
  content_type = "application/json"

  content = jsonencode({
    bastion_public_ip       = module.cluster.bastion_public_ip
    public_load_balancer_ip = module.network.public_nlb_ip_address
  })
}