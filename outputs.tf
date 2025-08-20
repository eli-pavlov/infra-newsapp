# outputs.tf
output "public_load_balancer_ip" {
  description = "Public IP address of the public-facing Network Load Balancer."
  value       = module.network.public_load_balancer_ip
}

output "bastion_public_ip" {
  description = "Public IP address of the bastion host for SSH access."
  value       = module.cluster.bastion_public_ip
}

output "control_plane_private_ip" {
  description = "Private IP of the control-plane node (accessible from the bastion)."
  value       = module.cluster.control_plane_private_ip
}