locals {
  private_ingress_ports = [
    80,
    443,
    6443
  ]
}

resource "oci_core_network_security_group" "private" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.cluster_name}-private-lb-nsg"
  vcn_id         = var.vcn_id
}

resource "oci_core_network_security_group_security_rule" "private" {
  for_each                  = toset([for p in local.private_ingress_ports : tostring(p)])
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  network_security_group_id = oci_core_network_security_group.private.id
  source                    = var.workers_subnet_cidr
  source_type               = "CIDR_BLOCK"
  stateless                 = false
  tcp_options {
    destination_port_range {
      max = tonumber(each.key)
      min = tonumber(each.key)
    }
  }
}
