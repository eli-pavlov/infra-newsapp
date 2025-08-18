locals {
  worker_private_ips = [for _, inst in oci_core_instance.app_workers : inst.private_ip]
  worker_ips_map     = { for ip in local.worker_private_ips : ip => ip }
}

# Public NLB → workers on NodePorts
resource "oci_network_load_balancer_backend" "http" {
  for_each                 = local.worker_ips_map
  network_load_balancer_id = var.public_nlb_id
  backend_set_name         = "k3s_http_backend"   # must match network module
  ip_address               = each.value
  port                     = var.ingress_controller_http_nodeport
  is_backup = false
  is_offline = false
  weight = 1
}

resource "oci_network_load_balancer_backend" "https" {
  for_each                 = local.worker_ips_map
  network_load_balancer_id = var.public_nlb_id
  backend_set_name         = "k3s_https_backend"
  ip_address               = each.value
  port                     = var.ingress_controller_https_nodeport
  is_backup = false
  is_offline = false
  weight = 1
}

# Private LB (kube-apiserver 6443) → control-plane
resource "oci_load_balancer_backend" "kubeapi" {
  load_balancer_id = var.private_lb_id
  backendset_name  = "K3s__kube_api_backend_set"
  ip_address       = oci_core_instance.control_plane.private_ip
  port             = 6443
  weight           = 1
}
