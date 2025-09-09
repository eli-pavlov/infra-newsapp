data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

# pick an AD (0,1,2) or however you select it today
locals {
  ad_name = data.oci_identity_availability_domains.ads.availability_domains[var.ad_index].name
}

resource "oci_core_instance" "bastion" {
  availability_domain = local.ad_name
  compartment_id      = var.compartment_ocid
  display_name        = "bastion"
  shape               = var.instance_shape

  create_vnic_details {
    subnet_id        = oci_core_subnet.public_subnet.id
    assign_public_ip = true
    nsg_ids          = [oci_core_network_security_group.bastion.id]
  }

  # keep your image selection as-is; example shown:
  source_details {
    source_type = "image"
    source_id   = var.image_ocid
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    # IMPORTANT: Base64-encode the rendered cloud-init!
    user_data = base64encode(
      templatefile("${path.module}/scripts/bastion-cloudinit.sh", {
        # add vars if your script expects any
      })
    )
  }
}
