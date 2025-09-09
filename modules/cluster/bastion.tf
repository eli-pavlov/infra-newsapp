resource "oci_core_instance" "bastion" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "bastion"

  # Use the same Flex shape knobs as the nodes (defaults are Flex)
  shape = var.node_shape
  shape_config {
    ocpus         = var.node_ocpus
    memory_in_gbs = var.node_memory_gb
  }

  create_vnic_details {
    subnet_id        = var.public_subnet_id
    assign_public_ip = true
    nsg_ids          = [var.bastion_nsg_id]
  }

  source_details {
    source_type = "image"
    source_id   = var.bastion_os_image_id
  }

  metadata = {
    ssh_authorized_keys = var.public_key_content
    # If you have cloud-init for bastion, uncomment and point to it:
    # user_data = base64encode(templatefile("${path.module}/files/bastion-cloudinit.sh", {}))
  }
}
