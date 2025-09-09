data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

locals {
  ad_name = data.oci_identity_availability_domains.ads.availability_domains[var.ad_index].name
}

resource "oci_core_instance" "control_plane" {
  availability_domain = local.ad_name
  compartment_id      = var.compartment_ocid
  display_name        = "k3s-control-plane"
  shape               = var.instance_shape

  # shape_config {...} if you’re using a flexible shape

  create_vnic_details {
    subnet_id        = oci_core_subnet.private_app_subnet.id
    assign_public_ip = false
    nsg_ids          = [oci_core_network_security_group.control_plane.id]
  }

  source_details {
    source_type = "image"
    source_id   = var.image_ocid
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(
      templatefile("${path.module}/scripts/k3s-server.sh", {
        T_K3S_VERSION          = var.k3s_version
        T_K3S_TOKEN            = var.k3s_token
        T_DB_USER              = var.db_user
        T_DB_NAME_DEV          = var.db_name_dev
        T_DB_NAME_PROD         = var.db_name_prod
        T_DB_SERVICE_NAME_DEV  = var.db_service_name_dev   # e.g. "postgresql-dev"
        T_DB_SERVICE_NAME_PROD = var.db_service_name_prod  # e.g. "postgresql-prod"
        T_MANIFESTS_REPO_URL   = var.manifests_repo_url
        T_EXPECTED_NODE_COUNT  = var.expected_node_count
        T_PRIVATE_LB_IP        = module.network.private_nlb_ip
      })
    )
  }
}
