# modules/cluster/nodes.tf

# =================== 1. Control Plane Node ===================
resource "oci_core_instance" "control_plane" {
  display_name        = "${var.cluster_name}-control-plane"
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
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

# =================== 2. Application Worker Nodes (x2) ===================
resource "oci_core_instance" "app_workers" {
  count = 2

  display_name        = "${var.cluster_name}-app-worker-${count.index + 1}"
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
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
    user_data           = templatefile("${path.module}/files/k3s-install-agent.sh", {
      k3s_version = var.k3s_version,
      k3s_token   = random_password.k3s_token.result,
      k3s_url_ip  = oci_core_instance.control_plane.private_ip,
      node_labels = "role=application",
      node_taints = ""
    })
  }

  depends_on = [oci_core_instance.control_plane]
}

# =================== 3. Database Worker Node (x1) ===================
resource "oci_core_instance" "db_worker" {
  display_name        = "${var.cluster_name}-db-worker-3"
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
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
    user_data           = templatefile("${path.module}/files/k3s-install-agent.sh", {
      k3s_version = var.k3s_version,
      k3s_token   = random_password.k3s_token.result,
      k3s_url_ip  = oci_core_instance.control_plane.private_ip,
      node_labels = "role=database",
      node_taints = "role=database:NoSchedule"
    })
  }

  depends_on = [oci_core_instance.control_plane]
}