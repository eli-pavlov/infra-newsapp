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
  value = oci_core_network_security_group.servers_kubeapi.id
}

output "workers_nsg_id" {
  value = oci_core_network_security_group.workers.id
}

output "public_nlb_id" {
  value = oci_network_load_balancer_network_load_balancer.k3s_public_lb.id
}

output "public_nlb_ip_address" {
  value = [for i in oci_network_load_balancer_network_load_balancer.k3s_public_lb.ip_addresses : i.ip_address if i.is_public][0]
}

output "private_lb_id" {
  value = oci_load_balancer_load_balancer.k3s_private_lb.id
}

output "private_lb_ip_address" {
  value = oci_load_balancer_load_balancer.k3s_private_lb.ip_address_details[0].ip_address
}
