resource "oci_core_instance" "control_plane" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "${var.cluster_name}-control-plane"
  shape               = var.node_shape
  shape_config {
    ocpus         = var.node_ocpus
    memory_in_gbs = var.node_memory_gb
  }

  create_vnic_details {
    subnet_id        = var.private_subnet_id
    assign_public_ip = false
    nsg_ids          = [var.control_plane_nsg_id]
  }

  source_details {
    source_type = "image"
    source_id   = var.os_image_id
  }

  metadata = {
    ssh_authorized_keys = var.public_key_content
    user_data           = data.cloudinit_config.k3s_server_tpl.rendered
  }
}

# ---------------------------------------------------------------
# Application workers (count)
# ---------------------------------------------------------------
resource "oci_core_instance" "app_workers" {
  count               = var.app_worker_count
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "${var.cluster_name}-app-${count.index}"
  shape               = var.node_shape
  shape_config {
    ocpus         = var.node_ocpus
    memory_in_gbs = var.node_memory_gb
  }

  create_vnic_details {
    subnet_id        = var.private_subnet_id
    assign_public_ip = false
    nsg_ids          = [var.workers_nsg_id]
  }

  source_details {
    source_type = "image"
    source_id   = var.os_image_id
  }

  metadata = {
    ssh_authorized_keys = var.public_key_content
    user_data = base64encode(
      templatefile("${path.module}/files/k3s-install-agent.sh", {
        T_K3S_VERSION = var.k3s_version
        T_K3S_TOKEN   = random_password.k3s_token.result
        T_K3S_URL_IP  = var.private_lb_ip_address
        T_NODE_LABELS = "role=application"
        T_NODE_TAINTS = ""
      })
    )
  }
}

# ---------------------------------------------------------------
# Database worker (single)
# ---------------------------------------------------------------
resource "oci_core_instance" "db_worker" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "${var.cluster_name}-db-0"
  shape               = var.node_shape
  shape_config {
    ocpus         = var.node_ocpus
    memory_in_gbs = var.node_memory_gb
  }

  create_vnic_details {
    subnet_id        = var.private_subnet_id
    assign_public_ip = false
    nsg_ids          = [var.workers_nsg_id]
  }

  source_details {
    source_type = "image"
    source_id   = var.os_image_id
  }

  metadata = {
    ssh_authorized_keys = var.public_key_content
    user_data = base64encode(
      templatefile("${path.module}/files/k3s-install-agent.sh", {
        T_K3S_VERSION = var.k3s_version
        T_K3S_TOKEN   = random_password.k3s_token.result
        T_K3S_URL_IP  = var.private_lb_ip_address
        T_NODE_LABELS = "role=database"
        T_NODE_TAINTS = "role=database:NoSchedule"
      })
    )
  }
}