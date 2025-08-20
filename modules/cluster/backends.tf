# modules/cluster/backends.tf

locals {
  # Combine the private IPs of all worker nodes into a single list
  all_worker_private_ips = toset(concat(
    [for inst in oci_core_instance.app_workers : inst.private_ip],
    [oci_core_instance.db_worker.private_ip],
  ))
}

# Add all workers to the Public NLB's HTTP backend set
resource "oci_network_load_balancer_backend" "http" {
  for_each                   = local.all_worker_private_ips
  network_load_balancer_id   = var.public_nlb_id
  backend_set_name           = "k8s_http_backend"
  ip_address                 = each.value
  port                       = 30080 # Ingress Controller HTTP NodePort
}

# Add all workers to the Public NLB's HTTPS backend set
resource "oci_network_load_balancer_backend" "https" {
  for_each                   = local.all_worker_private_ips
  network_load_balancer_id   = var.public_nlb_id
  backend_set_name           = "k8s_https_backend"
  ip_address                 = each.value
  port                       = 30443 # Ingress Controller HTTPS NodePort
}

# Point the Private LB to the control plane for the Kube API (port 6443)
resource "oci_load_balancer_backend" "kubeapi" {
  load_balancer_id = var.private_lb_id
  backendset_name  = "k8s_kube_api_backend_set"
  ip_address       = oci_core_instance.control_plane.private_ip
  port             = 6443
}