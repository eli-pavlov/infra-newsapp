# modules/cluster/output.tf
output "bastion_public_ip" {
  description = "Public IP of the bastion host for SSH access."
  value       = data.oci_core_public_ip.bastion.ip_address
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

# Expose the backend / backendset names via variables (cluster module receives them from root)
output "public_nlb_backend_set_http_name" {
  description = "Name of the HTTP backend set on the public NLB (passed into the cluster module)."
  value       = var.public_nlb_backend_set_http_name
}

output "public_nlb_backend_set_https_name" {
  description = "Name of the HTTPS backend set on the public NLB (passed into the cluster module)."
  value       = var.public_nlb_backend_set_https_name
}

output "private_lb_backendset_name" {
  description = "Name of the backend set on the private classic LB for kube-apiserver (passed into the cluster module)."
  value       = var.private_lb_backendset_name
}
