# modules/network/output.tf

output "public_subnet_id" {
  value = oci_core_subnet.public.id
}

output "private_subnet_id" {
  value = oci_core_subnet.private.id
}

output "bastion_nsg_id" {
  value = oci_core_network_security_group.bastion.id
}

output "control_plane_nsg_id" {
  value = oci_core_network_security_group.control_plane.id
}

output "workers_nsg_id" {
  value = oci_core_network_security_group.workers.id
}

output "public_nlb_id" {
  value = oci_network_load_balancer_network_load_balancer.public_nlb.id
}

output "public_nlb_ip_address" {
  # The first public IP address assigned to the NLB.
  value = oci_network_load_balancer_network_load_balancer.public_nlb.ip_addresses[0].ip_address
}

output "private_lb_id" {
  value = oci_load_balancer_load_balancer.private_lb.id
}

output "private_lb_ip_address" {
  # The first private IP address assigned to the LB.
  value = oci_load_balancer_load_balancer.private_lb.ip_address_details[0].ip_address
}

# === Added: expose backend set names so root can pass them to the cluster module ===
output "public_nlb_backend_set_http_name" {
  value = oci_network_load_balancer_backend_set.public_nlb_backends["http"].name
}

output "public_nlb_backend_set_https_name" {
  value = oci_network_load_balancer_backend_set.public_nlb_backends["https"].name
}

# Backend set name for kube-apiserver (6443)
output "private_lb_backendset_name" {
  description = "Backend set name on the private load balancer for the kube-apiserver (6443)."
  value       = oci_load_balancer_backend_set.private_lb_backendset_api.name
}

# Backend set name for RKE2 registration endpoint (9345)
output "private_lb_backendset_registration_name" {
  description = "Backend set name on the private load balancer for RKE2 registration (9345)."
  value       = oci_load_balancer_backend_set.private_lb_backendset_registration.name
}

output "private_subnet_cidr" {
  value = oci_core_subnet.private.cidr_block
}
