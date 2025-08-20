# main.tf
module "network" {
  source = "./modules/network"

  compartment_ocid   = var.compartment_ocid
  admin_cidrs      = var.admin_cidrs
  cloudflare_cidrs = var.cloudflare_cidrs
}

module "cluster" {
  source = "./modules/cluster"
  region = var.region
  public_nlb_ip_address = module.network.public_load_balancer_ip
  private_lb_ip_address = module.network.private_load_balancer_ip
  compartment_ocid      = var.compartment_ocid


  # General OCI Configuration
  availability_domain = var.availability_domain

  # Naming, Image, and Access
  cluster_name       = var.cluster_name
  os_image_id        = var.os_image_id
  public_key_content = var.public_key_content

  # Argo CD Configuration
  manifests_repo_url = var.manifests_repo_url

  # Network Inputs from the 'network' module
  public_subnet_id     = module.network.public_subnet_id
  private_subnet_id    = module.network.private_subnet_id
  bastion_nsg_id       = module.network.bastion_nsg_id
  control_plane_nsg_id = module.network.control_plane_nsg_id
  workers_nsg_id       = module.network.workers_nsg_id
  public_nlb_id        = module.network.public_nlb_id
  private_lb_id        = module.network.private_lb_id
}

# Upload a JSON file with key IPs to the OCI bucket after creation
resource "oci_objectstorage_object" "infra_outputs" {
  namespace = var.os_namespace    # CORRECTED from 'namespace'
  bucket         = var.tf_state_bucket # CORRECTED from 'bucket_name'
  object         = "infrastructure-outputs.json"
  content_type   = "application/json"

  content = jsonencode({
    bastion_public_ip       = module.cluster.bastion_public_ip
    public_load_balancer_ip = module.network.public_load_balancer_ip
  })
}