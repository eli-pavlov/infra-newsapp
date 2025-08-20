# main.tf

module "network" {
  source = "./modules/network"

  compartment_id   = var.compartment_ocid
  region           = var.region
  admin_cidrs      = var.admin_cidrs
  cloudflare_cidrs = var.cloudflare_cidrs
}

module "cluster" {
  source = "./modules/cluster"

  # General OCI Variables
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  region              = var.region

  # Naming and Image Variables
  cluster_name       = var.cluster_name
  os_image_id        = var.os_image_id
  public_key_content = var.public_key_content

  # Argo CD and Script Variables
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
  namespace    = var.os_namespace
  bucket_name  = var.tf_state_bucket
  object       = "infrastructure-outputs.json"
  content_type = "application/json"

  content = jsonencode({
    bastion_public_ip       = module.cluster.bastion_public_ip
    public_load_balancer_ip = module.network.public_load_balancer_ip
  })
}