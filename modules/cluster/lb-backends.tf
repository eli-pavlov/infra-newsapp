# --- Backends for the PRIVATE (Classic) LB -> Kube API:6443 ---
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

# --- ADD THIS NEW BACKEND RESOURCE ---
# --- Backends for the PRIVATE (Classic) LB -> RKE2 Registration:9345 ---
resource "oci_load_balancer_backend" "rke2_registration" {
  load_balancer_id = var.private_lb_id
  backendset_name  = var.private_lb_backendset_registration_name
  ip_address       = data.oci_core_vnic.cp.private_ip_address
  port             = 9345
  weight           = 1
  backup           = false
  drain            = false
  offline          = false
}


# Helper map of app worker IPs
locals {
  app_worker_ips = { for idx, vnic in data.oci_core_vnic.app : tostring(idx) => vnic.private_ip_address }
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
  
  depends_on = [
  oci_network_load_balancer_network_load_balancer.public_nlb,
  oci_network_load_balancer_backend_set.public_nlb_backends["https"]
  ]
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

  depends_on = [
  oci_network_load_balancer_network_load_balancer.public_nlb,
  oci_network_load_balancer_backend_set.public_nlb_backends["https"]
  ]
}
