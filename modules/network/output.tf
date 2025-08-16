output "public_nlb_id" {
  value = oci_network_load_balancer_network_load_balancer.k3s_public_lb.id
}

output "public_nlb_ip_address" {
  value = [for interface in oci_network_load_balancer_network_load_balancer.k3s_public_lb.ip_addresses : interface.ip_address if interface.is_public == true][0]
}

output "private_lb_id" {
  value = oci_load_balancer_load_balancer.k3s_private_lb.id
}

output "private_lb_ip_address" {
  value = oci_load_balancer_load_balancer.k3s_private_lb.ip_address_details[0].ip_address
}

output "workers_subnet_id" {
  value = oci_core_subnet.default_oci_core_subnet10.id
}

output "private_lb_security_group" {
  value = oci_core_network_security_group.private_lb.id
}

output "public_nlb_security_group" {
  value = oci_core_network_security_group.public_nlb.id
}

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