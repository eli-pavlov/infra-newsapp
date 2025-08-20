# modules/cluster/output.tf

output "bastion_public_ip" {
  description = "Public IP of the bastion host for SSH access."
  value       = oci_core_instance.bastion.public_ip
}

output "control_plane_private_ip" {
  description = "Private IP of the control-plane node."
  value       = oci_core_instance.control_plane.private_ip
}

output "app_worker_private_ips" {
  description = "Private IPs of the application worker nodes."
  value       = [for instance in oci_core_instance.app_workers : instance.private_ip]
}

output "db_worker_private_ip" {
  description = "Private IP of the database worker node."
  value       = oci_core_instance.db_worker.private_ip
}