resource "oci_core_vcn" "main" {
  cidr_block     = var.vcn_cidr
  compartment_id = var.compartment_ocid
  display_name   = "k8s-vcn"
  dns_label      = "k8svcn"
}

# Public Subnet for Bastion and Load Balancers
resource "oci_core_subnet" "public" {
  cidr_block        = var.public_subnet_cidr
  compartment_id    = var.compartment_ocid
  display_name      = "Public Subnet"
  dns_label         = "public"
  route_table_id    = oci_core_vcn.main.default_route_table_id
  security_list_ids = [oci_core_vcn.main.default_security_list_id]
  vcn_id            = oci_core_vcn.main.id
}

# Private Subnet for Kubernetes Nodes
resource "oci_core_subnet" "private" {
  cidr_block                 = var.private_subnet_cidr
  compartment_id             = var.compartment_ocid
  display_name               = "Private Subnet (K8s Nodes)"
  dns_label                  = "private"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_vcn.main.default_security_list_id]
  vcn_id                     = oci_core_vcn.main.id
}

# Internet Gateway for Public Subnet traffic
resource "oci_core_internet_gateway" "main" {
  compartment_id = var.compartment_ocid
  display_name   = "k8s-igw"
  vcn_id         = oci_core_vcn.main.id
}

# NAT Gateway for Private Subnet outbound traffic
resource "oci_core_nat_gateway" "main" {
  compartment_id = var.compartment_ocid
  display_name   = "k8s-nat-gw"
  vcn_id         = oci_core_vcn.main.id
}

# Route table for the public subnet
resource "oci_core_default_route_table" "public" {
  manage_default_resource_id = oci_core_vcn.main.default_route_table_id
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }
}

# Route table for the private subnet
resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "Private Route Table"
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.main.id
  }
}

# Basic security list allowing all egress and intra-VCN ingress
resource "oci_core_default_security_list" "main" {
  manage_default_resource_id = oci_core_vcn.main.default_security_list_id
  compartment_id             = var.compartment_ocid
  display_name               = "Default Security List"

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }

  ingress_security_rules {
    protocol = "all"
    source   = var.vcn_cidr
  }
}