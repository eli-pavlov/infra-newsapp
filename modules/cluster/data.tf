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
      k3s_version                     = var.k3s_version,
      k3s_subnet                      = var.k3s_subnet,
      k3s_token                       = random_password.k3s_token.result,
      disable_ingress                 = var.disable_ingress,
      ingress_controller              = var.ingress_controller,
      nginx_ingress_release           = var.nginx_ingress_release,
      k3s_url                         = var.private_lb_ip_address,
      k3s_tls_san                     = var.private_lb_ip_address,
      k3s_tls_san_public              = var.public_nlb_ip_address,
      ingress_controller_http_nodeport  = var.ingress_controller_http_nodeport,
      ingress_controller_https_nodeport = var.ingress_controller_https_nodeport,
      db_mount_path                   = var.db_mount_path,
      node3_name                      = var.node3_name
    })
  }
}

# =================== APP node #1 cloud-init ===================
data "cloudinit_config" "k3s_worker_tpl_app1" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/files/k3s-install-agent.sh", {
      k3s_version      = var.k3s_version,
      k3s_subnet       = var.k3s_subnet,
      k3s_token        = random_password.k3s_token.result,
      k3s_url          = var.private_lb_ip_address,
      db_volume_device = var.db_volume_device,
      db_mount_path    = var.db_mount_path,
      node_name        = var.node1_name,
      node_role        = "app"
    })
  }
}

# =================== APP node #2 cloud-init ===================
data "cloudinit_config" "k3s_worker_tpl_app2" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/files/k3s-install-agent.sh", {
      k3s_version      = var.k3s_version,
      k3s_subnet       = var.k3s_subnet,
      k3s_token        = random_password.k3s_token.result,
      k3s_url          = var.private_lb_ip_address,
      db_volume_device = var.db_volume_device,
      db_mount_path    = var.db_mount_path,
      node_name        = var.node2_name,
      node_role        = "app"
    })
  }
}

# =================== DB node cloud-init ===================
data "cloudinit_config" "k3s_worker_tpl_db" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/files/k3s-install-agent.sh", {
      k3s_version      = var.k3s_version,
      k3s_subnet       = var.k3s_subnet,
      k3s_token        = random_password.k3s_token.result,
      k3s_url          = var.private_lb_ip_address,
      db_volume_device = var.db_volume_device,
      db_mount_path    = var.db_mount_path,
      node_name        = var.node3_name,
      node_role        = "db"
    })
  }
}
