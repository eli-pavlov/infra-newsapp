locals {
  db_storage_ocid = coalesce(
    try(data.terraform_remote_state.storage.outputs.db_storage_ocid, null),
    var.db_storage_ocid
  )
}

resource "null_resource" "validate_db_storage_ocid" {
  count = local.db_storage_ocid == null || local.db_storage_ocid == "" ? 1 : 0
  provisioner "local-exec" {
    command = "echo 'ERROR: db_storage_ocid is empty. Ensure storage workspace created the volume and the remote state key is correct.' && exit 1"
  }
}


# Read the storage state file using the dedicated data source
data "terraform_remote_state" "storage" {
  backend = "oci"
  config = {
    bucket    = var.tf_state_bucket
    key       = var.storage_state_key
    namespace = var.os_namespace
    region    = var.region
  }
}
# Query the existing volume in OCI by OCID retrieved above
data "oci_core_volume" "db_volume" {
  volume_id = local.db_storage_ocid
}


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
  cloudflare_zone_id = var.cloudflare_zone_id
  argocd_host        = var.argocd_host
  
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
  cloudflare_api_token = var.cloudflare_api_token
  db_storage_ocid = local.db_storage_ocid 
  # AWS S3 for object storage
  aws_access_key_id     = var.aws_access_key_id
  aws_secret_access_key = var.aws_secret_access_key
  aws_region            = var.aws_region
  aws_bucket            = var.aws_bucket
  storage_type          = var.storage_type
  # sealed-secrets keypair (base64-encoded)
  sealed_secrets_cert   = var.sealed_secrets_cert
  sealed_secrets_key    = var.sealed_secrets_key
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
  public_nlb_postgres_backend_set_name     = module.network.public_nlb_backend_set_postgres_name
  public_nlb_postgres_dev_backend_set_name = module.network.public_nlb_backend_set_postgres_dev_name
  
  depends_on = [
  module.network
  ]
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