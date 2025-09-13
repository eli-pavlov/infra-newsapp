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

data "oci_core_vnic_attachments" "instance_vnics" {
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  instance_id         = oci_core_instance.bastion.id
}

data "oci_core_vnic" "instance_vnic1" {
  vnic_id = data.oci_core_vnic_attachments.instance_vnics.vnic_attachments[0]["vnic_id"]
}

data "oci_core_private_ips" "private_ips1" {
  vnic_id = data.oci_core_vnic.instance_vnic1.id
}

resource "oci_core_public_ip" "reserved_public_ip_assigned" {
  compartment_id = var.compartment_ocid
  display_name   = "reservedPublicIPAssigned"
  lifetime       = "RESERVED"
  private_ip_id  = data.oci_core_private_ips.private_ips1.private_ips[0]["id"]
}

data "oci_core_public_ips" "region_public_ips_list" {
  compartment_id = var.compartment_ocid
  scope          = "REGION"

  filter {
    name   = "id"
    values = [oci_core_public_ip.reserved_public_ip_assigned.id]
  }
}
output "public_ips" {
  value = [
    data.oci_core_public_ips.region_public_ips_list.public_ips,
  ]
}