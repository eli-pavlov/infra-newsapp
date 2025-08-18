# modules/cluster/output.tf

output "control_plane_public_ip" {
  description = "Public IP of the control-plane node."
  value       = oci_core_instance.control_plane.public_ip
}

output "app_worker_public_ips" {
  description = "Public IPs of the application worker nodes."
  value       = { for k, v in oci_core_instance.app_workers : k => v.public_ip }
}

output "db_worker_public_ip" {
  description = "Public IP of the database worker node."
  value       = oci_core_instance.db_worker.public_ip
}