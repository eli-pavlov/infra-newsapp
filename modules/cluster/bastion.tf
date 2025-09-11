# modules/cluster/bastion.tf

# Creates a reserved public IP for the bastion host
resource "oci_core_public_ip" "bastion" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.cluster_name}-bastion-public-ip"
  lifetime       = "RESERVED"
}

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
    # Assign a specific private IP for consistency.
    private_ip = "10.0.1.100"
  }

  source_details {
    source_type = "image"
    source_id   = var.bastion_os_image_id
  }

  metadata = {
    ssh_authorized_keys = var.public_key_content
  }
}

# Look up the bastion VNIC (data block present elsewhere in module; kept as-is)
data "oci_core_vnic_attachments" "bastion" {
  compartment_id = var.compartment_ocid
  instance_id    = oci_core_instance.bastion.id
}
data "oci_core_vnic" "bastion" {
  vnic_id = data.oci_core_vnic_attachments.bastion.vnic_attachments[0].vnic_id
}

# Explicitly assign the reserved public IP to the bastion's private IP.
# Add depends_on so Terraform waits for the instance and public IP to exist
# before attempting to resolve the vnic and perform the assignment.
resource "oci_core_public_ip_assignment" "bastion_public_ip_assignment" {
  private_ip_id = data.oci_core_vnic.bastion.private_ip_id
  public_ip_id  = oci_core_public_ip.bastion.id

  depends_on = [
    oci_core_instance.bastion,
    oci_core_public_ip.bastion
  ]
}
