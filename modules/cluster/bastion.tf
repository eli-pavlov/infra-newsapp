# modules/cluster/bastion.tf

# Bastion compute instance
resource "oci_core_instance" "bastion" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "${var.cluster_name}-bastion"
  shape               = "VM.Standard.E2.1.Micro"

  create_vnic_details {
    subnet_id        = var.public_subnet_id
    assign_public_ip = false
    nsg_ids          = [var.bastion_nsg_id]
    private_ip       = "10.0.1.100"
  }

  source_details {
    source_type = "image"
    source_id   = var.bastion_os_image_id
  }

  metadata = {
    ssh_authorized_keys = var.public_key_content
  }
}

resource "oci_core_public_ip" "bastion_reserved_public_ip" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.cluster_name}-bastion-public-ip"
  lifetime       = "RESERVED"
  private_ip_id = oci_core_private_ip.bastion_private_ip.id
}
