# === Cluster module: load balancer backends ===

# Backends for the PRIVATE (Classic) LB -> Kube API:6443
resource "oci_load_balancer_backend" "kube_api" {
  load_balancer_id = var.private_lb_id
  backendset_name  = var.private_lb_backendset_name
  ip_address       = data.oci_core_vnic.cp.private_ip_address
  port             = 6443
  weight           = 1
  backup           = false
  drain            = false
  offline          = false
}

# Helper maps of node IPs for the public Network Load Balancer.
# - app_worker_ips: all application worker nodes
# - app_backend_ips: if workers exist, use them; otherwise, fall back to the DB node
locals {
  app_worker_ips = {
    for idx, vnic in data.oci_core_vnic.app :
    tostring(idx) => vnic.private_ip_address
  }

  # If there is at least one app worker, use workers as backends.
  # If app_worker_count == 0 (no workers), use the DB node as the sole backend.
  app_backend_ips = length(keys(local.app_worker_ips)) > 0 ? local.app_worker_ips : {
    db = data.oci_core_vnic.db.private_ip_address
  }
}

# Public NLB backends: HTTP (NodePort 30080)
resource "oci_network_load_balancer_backend" "http" {
  for_each                 = local.app_backend_ips
  network_load_balancer_id = var.public_nlb_id
  backend_set_name         = var.public_nlb_backend_set_http_name
  name                     = "app-${each.key}-http"
  ip_address               = each.value
  port                     = 30080
  weight                   = 1
  is_backup                = false
  is_offline               = false
}

# Public NLB backends: HTTPS (NodePort 30443)
resource "oci_network_load_balancer_backend" "https" {
  for_each                 = local.app_backend_ips
  network_load_balancer_id = var.public_nlb_id
  backend_set_name         = var.public_nlb_backend_set_https_name
  name                     = "app-${each.key}-https"
  ip_address               = each.value
  port                     = 30443
  weight                   = 1
  is_backup                = false
  is_offline               = false
}
