# === NSG Definitions ===
resource "oci_core_network_security_group" "bastion" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "nsg-bastion"
}

resource "oci_core_network_security_group" "control_plane" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "nsg-k8s-control-plane"
}

resource "oci_core_network_security_group" "workers" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "nsg-k8s-workers"
}

resource "oci_core_network_security_group" "public_lb" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "nsg-public-lb"
}

resource "oci_core_network_security_group" "private_lb" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "nsg-private-lb"
}

# === NSG Rules ===

# 1. Bastion Rules
#    - Ingress: Allow SSH from admin IPs.
resource "oci_core_network_security_group_security_rule" "bastion_ssh_in" {
  network_security_group_id = oci_core_network_security_group.bastion.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source_type               = "CIDR_BLOCK"
  source                    = var.admin_cidrs[0]
  tcp_options { destination_port_range { min = 22, max = 22 } }
}

# 2. Control Plane Rules
#    - Ingress: Allow SSH (22) from the Bastion NSG.
#    - Ingress: Allow Kube API (6443) from the Private LB NSG.
resource "oci_core_network_security_group_security_rule" "cp_ssh_in_from_bastion" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.bastion.id
  tcp_options { destination_port_range { min = 22, max = 22 } }
}
resource "oci_core_network_security_group_security_rule" "cp_api_in_from_privatelb" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.private_lb.id
  tcp_options { destination_port_range { min = 6443, max = 6443 } }
}

# 3. Worker Node Rules
#    - Ingress: Allow NodePorts (30000-32767) from the Public LB NSG.
resource "oci_core_network_security_group_security_rule" "workers_nodeport_in_from_publiclb" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.public_lb.id
  tcp_options { destination_port_range { min = 30000, max = 32767 } }
}

# 4. Public LB Rules
#    - Ingress: Allow HTTP/S from Cloudflare CIDRs.
resource "oci_core_network_security_group_security_rule" "public_lb_ingress" {
  for_each                  = toset(var.cloudflare_cidrs)
  network_security_group_id = oci_core_network_security_group.public_lb.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source_type               = "CIDR_BLOCK"
  source                    = each.value
}

# 5. Private LB Rules
#    (No ingress rules needed as it only receives traffic from within the VCN, which is allowed by the Default Security List)