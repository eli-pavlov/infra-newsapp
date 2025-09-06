# --- Backends for the PRIVATE (Classic) LB -> Kube API:6443 ---
resource "oci_load_balancer_backend" "kube_api" {
  load_balancer_id = var.private_lb_id
  backendset_name  = var.private_lb_backendset_name
  ip_address       = oci_core_instance.control_plane.private_ip
  port             = 6443
  weight           = 1
  backup           = false
  drain            = false
  offline          = false
}

# Helper map of app worker IPs
locals {
  app_worker_ips = { for idx, inst in oci_core_instance.app_workers : tostring(idx) => inst.private_ip }
}

# --- Backends for the PUBLIC NLB -> ingress-nginx NodePorts 30080/30443 ---
resource "oci_network_load_balancer_backend" "http" {
  for_each                 = local.app_worker_ips
  network_load_balancer_id = var.public_nlb_id
  backend_set_name         = var.public_nlb_backend_set_http_name
  name                     = "app-${each.key}-http"
  ip_address               = each.value
  port                     = 30080
  weight                   = 1
  is_backup                = false
  is_offline               = false
}

resource "oci_network_load_balancer_backend" "https" {
  for_each                 = local.app_worker_ips
  network_load_balancer_id = var.public_nlb_id
  backend_set_name         = var.public_nlb_backend_set_https_name
  name                     = "app-${each.key}-https"
  ip_address               = each.value
  port                     = 30443
  weight                   = 1
  is_backup                = false
  is_offline               = false
}
