resource "oci_core_instance" "bastion" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "${var.cluster_name}-bastion"
  shape               = "VM.Standard.E2.1.Micro"

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
  }
}