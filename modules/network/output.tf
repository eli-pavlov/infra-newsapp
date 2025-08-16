output "private_lb_id" {
  description = "The OCID of the private load balancer."
  value       = oci_load_balancer_load_balancer.k3s_private_lb.id
}

output "private_lb_ip_address" {
  description = "The private IP address of the load balancer."
  value       = oci_load_balancer_load_balancer.k3s_private_lb.ip_address_details[0].ip_address
}

output "private_lb_security_group" {
  description = "The OCID of the security group for the private load balancer."
  value       = oci_core_network_security_group.private_lb.id
}

output "public_nlb_id" {
  description = "The OCID of the public network load balancer."
  value       = oci_network_load_balancer_network_load_balancer.k3s_public_lb.id
}

output "public_nlb_ip_address" {
  description = "The public IP address of the network load balancer."
  value       = oci_network_load_balancer_network_load_balancer.k3s_public_lb.ip_addresses[0].ip_address
}

output "public_nlb_security_group" {
  description = "The OCID of the security group for the public network load balancer."
  value       = oci_core_network_security_group.public_nlb.id
}
