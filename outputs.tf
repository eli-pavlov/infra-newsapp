output "public_nlb_ip_address" {
  value = module.network.public_nlb_ip_address
}

output "bastion_public_ip" {
  value = module.cluster.bastion_public_ip
}

output "control_plane_private_ip" {
  value = module.cluster.control_plane_private_ip
}

output "app_worker_private_ips" {
  value = module.cluster.app_worker_private_ips
}

output "db_worker_private_ip" {
  value = module.cluster.db_worker_private_ip
}
