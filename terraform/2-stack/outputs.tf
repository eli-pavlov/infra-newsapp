
# === Root outputs ===


output "public_nlb_ip_address" {
  description = "The public IP address of the Network Load Balancer for application traffic."
  value       = module.network.public_nlb_ip_address
}


output "control_plane_private_ip" {
  description = "The private IP address of the K3s control plane node."
  value       = module.cluster.control_plane_private_ip
}


output "app_worker_private_ips" {
  description = "The private IP addresses of the application worker nodes."
  value       = module.cluster.app_worker_private_ips
}


output "db_worker_private_ip" {
  description = "The private IP address of the database worker node."
  value       = module.cluster.db_worker_private_ip
}


output "public_nlb_backend_set_http_name" {
  value = module.network.public_nlb_backend_set_http_name
}


output "public_nlb_backend_set_https_name" {
  value = module.network.public_nlb_backend_set_https_name
}


output "private_lb_backendset_name" {
  value = module.network.private_lb_backendset_name
}

output "bastion_public_ip" {
  description = "The public IP address of the bastion host for SSH access."
  value       = module.cluster.bastion_public_ip
}