# modules/cluster/bastion.tf
#
# Creates the bastion host and a dedicated, reserved public IP address.

# A reserved public IP that won't change if the instance is recreated.
resource "oci_core_public_ip" "bastion" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.cluster_name}-bastion-public-ip"
  lifetime       = "RESERVED"
  # Use the private IP of the bastion's primary VNIC for assignment.
  # This creates an implicit dependency on the oci_core_instance resource.
  private_ip_id  = data.oci_core_vnic.bastion.private_ip_id
}

resource "oci_core_instance" "bastion" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "${var.cluster_name}-bastion"
  shape               = "VM.Standard.E2.1.Micro"

  create_vnic_details {
    subnet_id        = var.public_subnet_id
    # No longer assigning an ephemeral public IP.
    assign_public_ip = false
    nsg_ids          = [var.bastion_nsg_id]
    # Assign a specific private IP for consistency.
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
