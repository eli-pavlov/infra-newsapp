# modules/network/load-balancers.tf

#==================================================================
# 1. Public Network Load Balancer (for NGINX Ingress)
#==================================================================

resource "oci_network_load_balancer_network_load_balancer" "public_nlb" {
  compartment_id                 = var.compartment_ocid
  display_name                   = "k8s-public-nlb"
  subnet_id                      = oci_core_subnet.public.id
  is_private                     = false
  is_preserve_source_destination = false
  network_security_group_ids     = [oci_core_network_security_group.public_lb.id]
}

resource "oci_network_load_balancer_backend_set" "public_nlb_backends" {
  for_each                   = { for p in ["http", "https"] : p => p }
  name                       = "k8s_${each.key}_backend_set"
  network_load_balancer_id   = oci_network_load_balancer_network_load_balancer.public_nlb.id
  policy                     = "FIVE_TUPLE"
  is_preserve_source         = true
  health_checker {
    protocol = "TCP"
    # These are the default NodePorts for NGINX Ingress
    port     = each.key == "http" ? 30080 : 30443 
  }
}

resource "oci_network_load_balancer_listener" "public_nlb_listeners" {
  for_each                   = { for p in ["http", "https"] : p => p }
  name                       = "k8s_${each.key}_listener"
  network_load_balancer_id   = oci_network_load_balancer_network_load_balancer.public_nlb.id
  default_backend_set_name   = oci_network_load_balancer_backend_set.public_nlb_backends[each.key].name
  port                       = each.key == "http" ? 80 : 443
  protocol                   = "TCP"
}


#==================================================================
# 2. Private Standard Load Balancer (for Kube API)
#==================================================================

resource "oci_load_balancer_load_balancer" "private_lb" {
  compartment_id = var.compartment_ocid
  display_name   = "k8s-private-lb-api"
  shape          = "flexible"
  shape_details {
    minimum_bandwidth_in_mbps = 10
    maximum_bandwidth_in_mbps = 10
  }
  is_private                 = true
  subnet_ids                 = [oci_core_subnet.private.id] # Place LB in private subnet
  network_security_group_ids = [oci_core_network_security_group.private_lb.id]
}

resource "oci_load_balancer_backend_set" "private_lb_backendset" {
  name             = "k8s_kube_api_backend_set"
  load_balancer_id = oci_load_balancer_load_balancer.private_lb.id
  policy           = "ROUND_ROBIN"
  health_checker {
    protocol = "TCP"
    port     = 6443
  }
}

resource "oci_load_balancer_listener" "private_lb_listener" {
  name                       = "k8s_kube_api_listener"
  load_balancer_id           = oci_load_balancer_load_balancer.private_lb.id
  default_backend_set_name   = oci_load_balancer_backend_set.private_lb_backendset.name
  port                       = 6443
  protocol                   = "TCP"
}