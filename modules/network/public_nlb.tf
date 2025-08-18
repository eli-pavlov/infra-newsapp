locals {
  # Only HTTP/HTTPS are public. No public kubeapi.
  public_ingress_rules = {
    http = {
      listener_port = 80
      backend_port  = 30080
    }
    https = {
      listener_port = 443
      backend_port  = 30443
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

# Backend sets (health check the backend NodePort, not the listener port)
resource "oci_network_load_balancer_backend_set" "this" {
  for_each                 = local.public_ingress_rules
  name                     = "k3s_${each.key}_backend"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.k3s_public_lb.id
  policy                   = "FIVE_TUPLE"
  is_preserve_source       = true

  health_checker {
    protocol = "TCP"
    port     = each.value.backend_port
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

# NSG for the public NLB (ingress from Internet)
resource "oci_core_network_security_group" "public_nlb" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.default_oci_core_vcn.id
  display_name   = "K3S Public Network Load Balancer Security Group"
}

# Restrict 80 to Cloudflare IPs
resource "oci_core_network_security_group_security_rule" "public_http" {
  for_each                  = toset(var.cloudflare_cidrs)
  network_security_group_id = oci_core_network_security_group.public_nlb.id
  direction                 = "INGRESS"
  protocol                  = 6 # tcp

  description = "Allow HTTP (80) from ${each.key}"
  source      = each.key
  source_type = "CIDR_BLOCK"
  stateless   = false

  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}

# Restrict 443 to Cloudflare IPs
resource "oci_core_network_security_group_security_rule" "public_https" {
  for_each                  = toset(var.cloudflare_cidrs)
  network_security_group_id = oci_core_network_security_group.public_nlb.id
  direction                 = "INGRESS"
  protocol                  = 6 # tcp

  description = "Allow HTTPS (443) from ${each.key}"
  source      = each.key
  source_type = "CIDR_BLOCK"
  stateless   = false

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

# ---- Servers' NSG (only allow kubeapi from the PRIVATE LB) ----

resource "oci_core_network_security_group" "servers_kubeapi" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.default_oci_core_vcn.id
  display_name   = "K3S Servers kubeapi Security Group"
}

resource "oci_core_network_security_group_security_rule" "servers_allow_from_private_lb_6443" {
  network_security_group_id = oci_core_network_security_group.servers_kubeapi.id
  direction                 = "INGRESS"
  protocol                  = 6 # tcp

  description = "Allow kubeapi (6443) from Private LB"
  source_type = "NETWORK_SECURITY_GROUP"
  source      = oci_core_network_security_group.private_lb.id
  stateless   = false

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}
