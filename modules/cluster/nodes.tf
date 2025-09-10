# modules/cluster/nodes.tf

# =================== 1. Control Plane Node ===================
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
    # --- TEMPORARY CHANGE FOR PUBLIC IP ---
    subnet_id        = var.private_subnet_id
    #subnet_id        = var.public_subnet_id
    assign_public_ip = false
    nsg_ids          = [var.control_plane_nsg_id]
  }

  source_details {
    source_type = "image"
    source_id   = var.os_image_id
  }

  metadata = {
    ssh_authorized_keys = var.public_key_content
    # cloudinit_config already base64-encodes; pass rendered directly
    user_data = data.cloudinit_config.k3s_server_tpl.rendered
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
    #subnet_id        = var.public_subnet_id
    assign_public_ip = false
    nsg_ids          = [var.workers_nsg_id]
  }

  source_details {
    source_type = "image"
    source_id   = var.os_image_id
  }

  metadata = {
    ssh_authorized_keys = var.public_key_content
    # use the pre-built cloudinit bundle for app agents (no templatefile of the large script)
    user_data = data.cloudinit_config.k3s_agent_app_tpl.rendered
  }
  
  depends_on = [
    oci_core_instance.control_plane,
    oci_load_balancer_backend.kube_api
  ]
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
    #subnet_id        = var.public_subnet_id
    assign_public_ip = false
    nsg_ids          = [var.workers_nsg_id]
  }

  source_details {
    source_type = "image"
    source_id   = var.os_image_id
  }

  metadata = {
    ssh_authorized_keys = var.public_key_content
    # use the pre-built cloudinit bundle for db agent (no templatefile of the large script)
    user_data = data.cloudinit_config.k3s_agent_db_tpl.rendered
  }

  depends_on = [
    oci_core_instance.control_plane,
    oci_load_balancer_backend.kube_api
  ]
}
