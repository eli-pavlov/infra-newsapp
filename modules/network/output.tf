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
  value = oci_load_balancer_load_balancer.private_lb.ip_addresses[0].ip_address
}