# modules/cluster/data.tf

# K3s token for cluster join authentication
resource "random_password" "k3s_token" {
  length  = 55
  special = false
}

# =================== CONTROL-PLANE cloud-init ===================
data "cloudinit_config" "k3s_server_tpl" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/files/k3s-install-server.sh", {
      k3s_version               = var.k3s_version,
      k3s_token                 = random_password.k3s_token.result,
      # k3s_url_ip              = oci_core_instance.control_plane.private_ip, # REMOVE THIS LINE
      db_user                   = var.db_user,
      db_name_dev               = var.db_name_dev,
      db_name_prod              = var.db_name_prod,
      db_service_name_dev       = var.db_service_name_dev,
      db_service_name_prod      = var.db_service_name_prod,
      manifests_repo_url        = var.manifests_repo_url,
      expected_total_node_count = var.expected_total_node_count
    })
  }
}