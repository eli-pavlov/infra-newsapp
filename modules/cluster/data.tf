# K3s token for cluster join authentication
resource "random_password" "k3s_token" {
  length  = 55
  special = false
}

# =================== CONTROL-PLANE cloud-init ===================
data "cloudinit_config" "k3s_server_tpl" {
  gzip            = true
  base64_encode   = true

  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/files/k3s-install-server.sh", {
      T_K3S_VERSION          = var.k3s_version,
      T_K3S_TOKEN            = random_password.k3s_token.result,
      T_DB_USER              = var.db_user,
      T_DB_NAME_DEV          = var.db_name_dev,
      T_DB_NAME_PROD         = var.db_name_prod,
      T_DB_SERVICE_NAME_DEV  = var.db_service_name_dev,
      T_DB_SERVICE_NAME_PROD = var.db_service_name_prod,
      T_MANIFESTS_REPO_URL   = var.manifests_repo_url,
      T_EXPECTED_NODE_COUNT  = local.expected_total_node_count,
      T_PRIVATE_LB_IP        = var.private_lb_ip_address
    })
  }
}

# =================== VNIC lookups for instance IPs ===================

# Control plane
data "oci_core_vnic_attachments" "cp" {
  compartment_id = var.compartment_ocid
  instance_id    = oci_core_instance.control_plane.id
}
data "oci_core_vnic" "cp" {
  vnic_id = data.oci_core_vnic_attachments.cp.vnic_attachments[0].vnic_id
}

# Bastion
data "oci_core_vnic_attachments" "bastion" {
  compartment_id = var.compartment_ocid
  instance_id    = oci_core_instance.bastion.id
}
data "oci_core_vnic" "bastion" {
  vnic_id = data.oci_core_vnic_attachments.bastion.vnic_attachments[0].vnic_id
}

# App workers (map by index)
data "oci_core_vnic_attachments" "app" {
  for_each       = { for idx, inst in oci_core_instance.app_workers : idx => inst.id }
  compartment_id = var.compartment_ocid
  instance_id    = each.value
}
data "oci_core_vnic" "app" {
  for_each = data.oci_core_vnic_attachments.app
  vnic_id  = each.value.vnic_attachments[0].vnic_id
}

# DB worker
data "oci_core_vnic_attachments" "db" {
  compartment_id = var.compartment_ocid
  instance_id    = oci_core_instance.db_worker.id
}
data "oci_core_vnic" "db" {
  vnic_id = data.oci_core_vnic_attachments.db.vnic_attachments[0].vnic_id
}