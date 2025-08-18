locals {
  # Split listener (public) ports from backend (node) ports
  public_ingress_rules = {
    http = {
      source        = "0.0.0.0/0"
      listener_port = 80
      backend_port  = 30080
    }
    https = {
      source        = "0.0.0.0/0"
      listener_port = 443
      backend_port  = 30443
    }
    kubeapi = {
      source        = var.my_public_ip_cidr
      listener_port = 6443
      backend_port  = 6443
    }
  }
}

# Public NLB
resource "oci_network_load_balancer_network_load_balancer" "k3s_public_lb" {
  compartment_id             = var.compartment_ocid
  display_name               = "K3S Public Network Load Balancer"
  subnet_id                  = oci_core_subnet.oci_core_subnet11.id
  network_security_group_ids = [oci_core_network_security_group.public_nlb.id]

  is_private                     = false
  is_preserve_source_destination = false
}

# Backend Sets
resource "oci_network_load_balancer_backend_set" "this" {
  for_each                 = local.public_ingress_rules
  name                     = "k3s_${each.key}_backend"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_lb.id
  policy                   = "FIVE_TUPLE"
  is_preserve_source       = true

  health_checker {
    protocol = "TCP"
    # IMPORTANT: health check the backend NodePort, not the listener port
    port = each.value.backend_port
  }
}

# Listeners (public-facing ports)
resource "oci_network_load_balancer_listener" "this" {
  for_each                 = local.public_ingress_rules
  default_backend_set_name = oci_network_load_balancer_backend_set.this[each.key].name
  name                     = "k3s_${each.key}_listener"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_lb.id
  port                     = each.value.listener_port
  protocol                 = "TCP"
}

# Security Group for the NLB (ingress from the Internet to the NLB listener ports)
resource "oci_core_network_security_group" "public_nlb" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.default_oci_core_vcn.id
  display_name   = "K3S Public Network Load Balancer Security Group"
}

# Allow Internet to hit the listener ports (80/443) and admin CIDR to hit 6443
resource "oci_core_network_security_group_security_rule" "public" {
  for_each                  = local.public_ingress_rules
  network_security_group_id = oci_core_network_security_group.public_nlb.id
  direction                 = "INGRESS"
  protocol                  = 6 # tcp

  description = "Allow ${each.key} from ${each.value.source}"

  source      = each.value.source
  source_type = "CIDR_BLOCK"
  stateless   = false

  tcp_options {
    destination_port_range {
      max = each.value.listener_port
      min = each.value.listener_port
    }
  }
}
