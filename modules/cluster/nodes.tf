# modules/cluster/nodes.tf

# =================== 1. Control Plane (Master) Node ===================
resource "oci_core_instance" "control_plane" {
  display_name        = "${var.cluster_name}-control-plane"
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  shape               = var.compute_shape
  shape_config {
    ocpus         = "1"
    memory_in_gbs = "6"
  }

  create_vnic_details {
    subnet_id        = var.workers_subnet_id
    assign_public_ip = true
    # This node needs access rules for both the API and for egress traffic via the NLB
    nsg_ids = [var.servers_kubeapi_nsg_id, var.workers_http_nsg_id]
  }

  source_details {
    source_type = "image"
    source_id    = var.os_image_id
  }

  metadata = {
    ssh_authorized_keys = var.public_key_content
    # The cloudinit_config data source already handles base64 encoding
    user_data = data.cloudinit_config.k3s_server_tpl.rendered
  }
}

# =================== 2. Application Worker Nodes (node-1, node-2) ===================
resource "oci_core_instance" "app_workers" {
  # Create two app nodes using a map for iteration
  for_each = {
    "node-1" = { cloud_init = data.cloudinit_config.k3s_worker_tpl_app1.rendered }
    "node-2" = { cloud_init = data.cloudinit_config.k3s_worker_tpl_app2.rendered }
  }

  display_name        = "${var.cluster_name}-${each.key}"
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  shape               = var.compute_shape
  shape_config {
    ocpus         = "1"
    memory_in_gbs = "6"
  }

  create_vnic_details {
    subnet_id        = var.workers_subnet_id
    assign_public_ip = true
    nsg_ids          = [var.workers_http_nsg_id]
  }

  source_details {
    source_type = "image"
    source_id    = var.os_image_id
  }

  metadata = {
    ssh_authorized_keys = var.public_key_content
    user_data           = each.value.cloud_init
  }

  # Ensure the server is ready before workers try to join
  depends_on = [oci_core_instance.control_plane]
}

# =================== 3. Database Worker Node (node-3) ===================
resource "oci_core_instance" "db_worker" {
  display_name        = "${var.cluster_name}-node-3-db"
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  shape               = var.compute_shape
  shape_config {
    ocpus         = "1"
    memory_in_gbs = "6"
  }

  create_vnic_details {
    subnet_id        = var.workers_subnet_id
    assign_public_ip = true
    nsg_ids          = [var.workers_http_nsg_id]
  }

  source_details {
    source_type = "image"
    source_id    = var.os_image_id
  }

  metadata = {
    ssh_authorized_keys = var.public_key_content
    user_data           = data.cloudinit_config.k3s_worker_tpl_db.rendered
  }

  depends_on = [oci_core_instance.control_plane]
}
