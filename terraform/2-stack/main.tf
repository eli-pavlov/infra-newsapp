
# === Local values ===
# db_storage_ocid: OCID for the database storage volume, from remote state or variable fallback
locals {
  db_storage_ocid = coalesce(
    try(data.terraform_remote_state.storage.outputs.db_storage_ocid, null),
    var.db_storage_ocid
  )
}

# Validation: warn if db_storage_ocid is not set, but do not fail the apply
resource "null_resource" "warn_db_storage_optional" {
  count = local.db_storage_ocid == null || local.db_storage_ocid == "" ? 1 : 0
  provisioner "local-exec" {
    command = "echo 'INFO: db_storage_ocid is empty; DB will use local/ephemeral storage. Volume attachment will be skipped.'"
  }
}


# --- Remote state and data sources ---
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


# Fetch SSH public key from object storage
data "oci_objectstorage_object" "ssh_public_key" {
  namespace = var.os_namespace
  bucket    = var.tf_state_bucket
  object    = "oracle.key.pub"
}

# --- Network module ---
module "network" {
  source           = "../../modules/network/"
  compartment_ocid = var.compartment_ocid
  region           = var.region
  admin_cidrs      = var.admin_cidrs
  cloudflare_cidrs = var.cloudflare_cidrs
  cloudflare_zone_id = var.cloudflare_zone_id
  argocd_host        = var.argocd_host
}

  
# --- Cluster module ---
module "cluster" {
  source = "../../modules/cluster"
  region                = var.region
  availability_domain   = var.availability_domain
  compartment_ocid      = var.compartment_ocid
  cluster_name          = var.cluster_name
  app_worker_count     = 1
  public_key_content    = data.oci_objectstorage_object.ssh_public_key.content
  os_image_id           = var.os_image_id
  bastion_os_image_id   = var.bastion_os_image_id
  manifests_repo_url    = var.manifests_repo_url
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
  attach_db_volume = false
  db_storage_ocid  = ""  # optional; won’t matter while attach_db_volume=false
  
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