# ==================================================================
# Network Security Groups (NSGs) and rules
# ==================================================================


# Filter IPv4 from mixed CIDR lists (IPv6 contains ':')
locals {
  cloudflare_ipv4_cidrs = [for c in var.cloudflare_cidrs : trimspace(c) if !can(regex(":", c))]
  admin_ipv4_cidrs      = [for c in var.admin_cidrs : trimspace(c) if !can(regex(":", c))]

  # Combine + de-dup for Public LB ingress
  public_lb_ingress_cidrs = distinct(concat(local.cloudflare_ipv4_cidrs, local.admin_ipv4_cidrs))
}

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

# 1) Bastion: allow SSH from all admin IPv4s.
resource "oci_core_network_security_group_security_rule" "bastion_ssh_in" {
  for_each                    = toset(local.admin_ipv4_cidrs)
  network_security_group_id = oci_core_network_security_group.bastion.id
  direction                   = "INGRESS"
  protocol                    = "6" # TCP
  source_type                 = "CIDR_BLOCK"
  source                      = each.value

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

# --- TEMPORARY SSH ACCESS RULES ---
# To allow direct SSH access to all K8s nodes from your admin IPs for testing,

# resource "oci_core_network_security_group_security_rule" "cp_ssh_in_from_admin_cidrs_temporary" {
#   for_each                    = toset(local.admin_ipv4_cidrs)
#   network_security_group_id = oci_core_network_security_group.control_plane.id
#   direction                   = "INGRESS"
#   protocol                    = "6" # TCP
#   source_type                 = "CIDR_BLOCK"
#   source                      = each.value
#   description                 = "Temporary direct SSH access for admin"

#   tcp_options {
#     destination_port_range {
#       min = 22
#       max = 22
#     }
#   }
# }

# resource "oci_core_network_security_group_security_rule" "workers_ssh_in_from_admin_cidrs_temporary" {
#   for_each                    = toset(local.admin_ipv4_cidrs)
#   network_security_group_id = oci_core_network_security_group.workers.id
#   direction                   = "INGRESS"
#   protocol                    = "6" # TCP
#   source_type                 = "CIDR_BLOCK"
#   source                      = each.value
#   description                 = "Temporary direct SSH access for admin"

#   tcp_options {
#     destination_port_range {
#       min = 22
#       max = 22
#     }
#   }
# }



# 2) Control Plane:
#    - allow SSH from bastion
#    - allow kube API (6443) from private LB
resource "oci_core_network_security_group_security_rule" "cp_ssh_in_from_bastion" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                   = "INGRESS"
  protocol                    = "6"
  source_type                 = "NETWORK_SECURITY_GROUP"
  source                      = oci_core_network_security_group.bastion.id

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cp_api_in_from_privatelb" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                   = "INGRESS"
  protocol                    = "6"
  source_type                 = "NETWORK_SECURITY_GROUP"
  source                      = oci_core_network_security_group.private_lb.id

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cp_registration_in_from_privatelb" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                   = "INGRESS"
  protocol                    = "6" # TCP
  source_type                 = "NETWORK_SECURITY_GROUP"
  source                      = oci_core_network_security_group.private_lb.id

  tcp_options {
    destination_port_range {
      min = 9345
      max = 9345
    }
  }
}

resource "oci_core_network_security_group_security_rule" "private_lb_registration_from_workers" {
  network_security_group_id = oci_core_network_security_group.private_lb.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.workers.id

  tcp_options {
    destination_port_range {
      min = 9345
      max = 9345
    }
  }
}

# Allow private_lb to reach control_plane on 9345
resource "oci_core_network_security_group_security_rule" "private_lb_to_cp_registration_egress" {
  network_security_group_id = oci_core_network_security_group.private_lb.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination_type          = "NETWORK_SECURITY_GROUP"
  destination               = oci_core_network_security_group.control_plane.id

  tcp_options {
    destination_port_range {
      min = 9345
      max = 9345
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cp_healthcheck_in_from_subnet" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                   = "INGRESS"
  protocol                    = "6" # TCP
  source_type                 = "CIDR_BLOCK"
  source                      = var.private_subnet_cidr
  description                 = "Allow LB Health Checks from within the private subnet"

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cp_registration_healthcheck_in_from_subnet" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source_type               = "CIDR_BLOCK"
  source                    = var.private_subnet_cidr
  description               = "Allow LB health checks from within the private subnet to RKE2 registration (9345)"

  tcp_options {
    destination_port_range {
      min = 9345
      max = 9345
    }
  }
}

# 3) Workers:
#    - allow NodePorts (30000-32767) from the public LB (TCP & UDP)
#    - allow SSH from bastion
resource "oci_core_network_security_group_security_rule" "workers_nodeport_tcp_in_from_publiclb" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                   = "INGRESS"
  protocol                    = "6" # TCP
  source_type                 = "NETWORK_SECURITY_GROUP"
  source                      = oci_core_network_security_group.public_lb.id

  tcp_options {
    destination_port_range {
      min = 30000
      max = 32767
    }
  }
}

resource "oci_core_network_security_group_security_rule" "workers_nodeport_udp_in_from_publiclb" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                   = "INGRESS"
  protocol                    = "17" # UDP
  source_type                 = "NETWORK_SECURITY_GROUP"
  source                      = oci_core_network_security_group.public_lb.id

  udp_options {
    destination_port_range {
      min = 30000
      max = 32767
    }
  }
}

resource "oci_core_network_security_group_security_rule" "workers_ssh_in_from_bastion" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                   = "INGRESS"
  protocol                    = "6" # TCP
  source_type                 = "NETWORK_SECURITY_GROUP"
  source                      = oci_core_network_security_group.bastion.id

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

# 4a) Public LB: allow HTTPS from Cloudflare + Admin IPv4s
resource "oci_core_network_security_group_security_rule" "public_lb_https_ingress" {
  for_each                    = toset(local.public_lb_ingress_cidrs)
  network_security_group_id = oci_core_network_security_group.public_lb.id
  direction                   = "INGRESS"
  protocol                    = "6" # TCP
  source_type                 = "CIDR_BLOCK"
  source                      = each.value

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

# Public LB: allow HTTP from Cloudflare + Admin IPv4s (ACME/http->https, etc.)
resource "oci_core_network_security_group_security_rule" "public_lb_http_ingress" {
  for_each                    = toset(local.public_lb_ingress_cidrs)
  network_security_group_id = oci_core_network_security_group.public_lb.id
  direction                   = "INGRESS"
  protocol                    = "6" # TCP
  source_type                 = "CIDR_BLOCK"
  source                      = each.value

  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}


# 4b) Public LB -> Workers: egress to NodePort range (so the NLB can reach backends).
resource "oci_core_network_security_group_security_rule" "public_lb_to_workers_nodeports_egress_tcp" {
  network_security_group_id = oci_core_network_security_group.public_lb.id
  direction                   = "EGRESS"
  protocol                    = "6"
  destination_type            = "NETWORK_SECURITY_GROUP"
  destination                 = oci_core_network_security_group.workers.id

  tcp_options {
    destination_port_range {
      min = 30000
      max = 32767
    }
  }
}

resource "oci_core_network_security_group_security_rule" "public_lb_to_workers_nodeports_egress_udp" {
  network_security_group_id = oci_core_network_security_group.public_lb.id
  direction                   = "EGRESS"
  protocol                    = "17"
  destination_type            = "NETWORK_SECURITY_GROUP"
  destination                 = oci_core_network_security_group.workers.id

  udp_options {
    destination_port_range {
      min = 30000
      max = 32767
    }
  }
}

# 5) Private LB ingress: allow agents and control plane to reach kube-apiserver via LB:6443
resource "oci_core_network_security_group_security_rule" "private_lb_ingress_from_workers_6443" {
  network_security_group_id = oci_core_network_security_group.private_lb.id
  direction                   = "INGRESS"
  protocol                    = "6" # TCP
  source_type                 = "NETWORK_SECURITY_GROUP"
  source                      = oci_core_network_security_group.workers.id

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "private_lb_ingress_from_cp_6443" {
  network_security_group_id = oci_core_network_security_group.private_lb.id
  direction                   = "INGRESS"
  protocol                    = "6"
  source_type                 = "NETWORK_SECURITY_GROUP"
  source                      = oci_core_network_security_group.control_plane.id

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

# 6) Private LB -> Control Plane: egress to kube-apiserver (6443).
resource "oci_core_network_security_group_security_rule" "private_lb_to_cp_egress" {
  network_security_group_id = oci_core_network_security_group.private_lb.id
  direction                   = "EGRESS"
  protocol                    = "6" # TCP
  destination_type            = "NETWORK_SECURITY_GROUP"
  destination                 = oci_core_network_security_group.control_plane.id

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

# --- Generic egress (bastion / control-plane / workers) ---
resource "oci_core_network_security_group_security_rule" "bastion_egress_all" {
  network_security_group_id = oci_core_network_security_group.bastion.id
  direction                   = "EGRESS"
  protocol                    = "all"
  destination_type            = "CIDR_BLOCK"
  destination                 = "0.0.0.0/0"
}

resource "oci_core_network_security_group_security_rule" "cp_egress_all" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                   = "EGRESS"
  protocol                    = "all"
  destination_type            = "CIDR_BLOCK"
  destination                 = "0.0.0.0/0"
}

resource "oci_core_network_security_group_security_rule" "workers_egress_all" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                   = "EGRESS"
  protocol                    = "all"
  destination_type            = "CIDR_BLOCK"
  destination                 = "0.0.0.0/0"
}

# --- Flannel VXLAN (UDP/8472) between all nodes ---
resource "oci_core_network_security_group_security_rule" "cp_flannel_in_from_cp" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                   = "INGRESS"
  protocol                    = "17" # UDP
  source_type                 = "NETWORK_SECURITY_GROUP"
  source                      = oci_core_network_security_group.control_plane.id

  udp_options {
    destination_port_range {
      min = 8472
      max = 8472
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cp_flannel_in_from_workers" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                   = "INGRESS"
  protocol                    = "17"
  source_type                 = "NETWORK_SECURITY_GROUP"
  source                      = oci_core_network_security_group.workers.id

  udp_options {
    destination_port_range {
      min = 8472
      max = 8472
    }
  }
}

resource "oci_core_network_security_group_security_rule" "workers_flannel_in_from_cp" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                   = "INGRESS"
  protocol                    = "17"
  source_type                 = "NETWORK_SECURITY_GROUP"
  source                      = oci_core_network_security_group.control_plane.id

  udp_options {
    destination_port_range {
      min = 8472
      max = 8472
    }
  }
}

resource "oci_core_network_security_group_security_rule" "workers_flannel_in_from_workers" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                   = "INGRESS"
  protocol                    = "17"
  source_type                 = "NETWORK_SECURITY_GROUP"
  source                      = oci_core_network_security_group.workers.id

  udp_options {
    destination_port_range {
      min = 8472
      max = 8472
    }
  }
}

# --- Kubelet (TCP/10250) control-plane -> workers ---
resource "oci_core_network_security_group_security_rule" "workers_kubelet_in_from_cp" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                   = "INGRESS"
  protocol                    = "6" # TCP
  source_type                 = "NETWORK_SECURITY_GROUP"
  source                      = oci_core_network_security_group.control_plane.id

  tcp_options {
    destination_port_range {
      min = 10250
      max = 10250
    }
  }
}