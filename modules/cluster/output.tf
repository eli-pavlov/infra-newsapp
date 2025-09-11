# modules/cluster/output.tf

output "bastion_public_ip" {
  description = "Public IP of the bastion host for SSH access."
  # Now outputs the value of the reserved public IP resource.
  value       = oci_core_public_ip.bastion.ip_address
}

output "control_plane_private_ip" {
  description = "Private IP of the control-plane node."
  value       = data.oci_core_vnic.cp.private_ip_address
}

output "app_worker_private_ips" {
  description = "Private IPs of the application worker nodes."
  value       = [for _, v in data.oci_core_vnic.app : v.private_ip_address]
}

output "db_worker_private_ip" {
  description = "Private IP of the database worker node."
  value       = data.oci_core_vnic.db.private_ip_address
}