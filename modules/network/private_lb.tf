# Private LB for kubeapi (in the private subnet)
resource "oci_load_balancer_load_balancer" "k3s_private_lb" {
  lifecycle { ignore_changes = [network_security_group_ids] }

  compartment_id = var.compartment_ocid
  display_name   = "K3S Private Load Balancer"
  shape          = "flexible"
  subnet_ids     = [oci_core_subnet.private.id]

  ip_mode    = "IPV4"
  is_private = true

  shape_details {
    maximum_bandwidth_in_mbps = 10
    minimum_bandwidth_in_mbps = 10
  }
}

resource "oci_load_balancer_backend_set" "k3s_kube_api_backend_set" {
  health_checker {
    protocol = "TCP"
    port     = 6443
  }
  load_balancer_id = oci_load_balancer_load_balancer.k3s_private_lb.id
  name             = "k8s_kube_api_backend_set"
  policy           = "ROUND_ROBIN"
}

resource "oci_load_balancer_listener" "k3s_kube_api_listener" {
  default_backend_set_name = oci_load_balancer_backend_set.k3s_kube_api_backend_set.name
  load_balancer_id         = oci_load_balancer_load_balancer.k3s_private_lb.id
  name                     = "kube_api_listener"
  port                     = 6443
  protocol                 = "TCP"
}

# Private LB NSG
resource "oci_core_network_security_group" "private_lb" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "K3S Private Load Balancer Security Group"
}

# Allow Servers' NSG to receive 6443 only from Private LB
resource "oci_core_network_security_group_security_rule" "servers_allow_from_private_lb_6443" {
  network_security_group_id = oci_core_network_security_group.servers_kubeapi.id
  direction                 = "INGRESS"
  protocol                  = 6
  description               = "Allow kubeapi (6443) from Private LB"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.private_lb.id
  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}