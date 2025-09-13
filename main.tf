data "oci_objectstorage_object" "ssh_public_key" {
  namespace = var.os_namespace
  bucket    = var.tf_state_bucket
  object    = "oracle.key.pub"
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
  public_key_content    = data.oci_objectstorage_object.ssh_public_key.content
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
  public_nlb_backend_set_http_name  = module.network.public_nlb_backend_set_http_name
  public_nlb_backend_set_https_name = module.network.public_nlb_backend_set_https_name
  private_lb_backendset_name        = module.network.private_lb_backendset_name
  private_lb_backendset_registration_name = module.network.private_lb_backendset_registration_name
  depends_on = [module.network]

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