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
      T_K3S_VERSION         = var.k3s_version,
      T_K3S_TOKEN           = random_password.k3s_token.result,
      T_DB_USER             = var.db_user,
      T_DB_NAME_DEV         = var.db_name_dev,
      T_DB_NAME_PROD        = var.db_name_prod,
      T_DB_SERVICE_NAME_DEV = var.db_service_name_dev,
      T_DB_SERVICE_NAME_PROD= var.db_service_name_prod,
      T_MANIFESTS_REPO_URL  = var.manifests_repo_url,
      T_EXPECTED_NODE_COUNT = var.expected_total_node_count,
      T_PRIVATE_LB_IP       = var.private_lb_ip_address
    })
  }
}
