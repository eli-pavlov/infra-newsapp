
# ==================================================================
# Network Security Groups (NSGs) and rules
# This file defines all NSGs and their security rules for the cluster network.
# Each NSG is associated with a logical group of nodes or load balancers.
# Rules are grouped by function and direction (ingress/egress).
#
# Key:
# - NSG: Network Security Group
# - LB: Load Balancer
# - CP: Control Plane
# - NLB: Network Load Balancer
# - VXLAN: Virtual Extensible LAN (Flannel overlay)
#
# See module variables for CIDR and group inputs.
# ==================================================================



# --- Local values for IPv4 filtering and ingress sources ---
locals {
  # Filter only IPv4 CIDRs from Cloudflare and admin lists (exclude IPv6)
  cloudflare_ipv4_cidrs = [for c in var.cloudflare_cidrs : trimspace(c) if !can(regex(":", c))]
  admin_ipv4_cidrs      = [for c in var.admin_cidrs : trimspace(c) if !can(regex(":", c))]

  # Combine and de-duplicate for Public LB ingress rules
  public_lb_ingress_cidrs = distinct(concat(local.cloudflare_ipv4_cidrs, local.admin_ipv4_cidrs))
}


# === NSG Definitions ===
# Each NSG groups related compute or LB resources for targeted security rules.

# Bastion host NSG
resource "oci_core_network_security_group" "bastion" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "nsg-bastion"
}

# Kubernetes control plane NSG
resource "oci_core_network_security_group" "control_plane" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "nsg-k8s-control-plane"
}

# Kubernetes workers NSG
resource "oci_core_network_security_group" "workers" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "nsg-k8s-workers"
}

# Public load balancer NSG
resource "oci_core_network_security_group" "public_lb" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "nsg-public-lb"
}

# Private load balancer NSG
resource "oci_core_network_security_group" "private_lb" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "nsg-private-lb"
}


# === NSG Rules ===
# Each rule is grouped by NSG and function. Comments explain the intent and scope.

# 1) Bastion: allow SSH from all admin IPv4s.
resource "oci_core_network_security_group_security_rule" "bastion_ssh_in" {
  for_each                  = toset(local.admin_ipv4_cidrs)
  network_security_group_id = oci_core_network_security_group.bastion.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source_type               = "CIDR_BLOCK"
  source                    = each.value
  # Allow SSH from each admin IPv4
  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}


# --- TEMPORARY SSH ACCESS RULES ---
# Uncomment these for direct SSH to control-plane/workers from admin IPs (testing only)




# 2) Control Plane:
#    - SSH from bastion only
#    - Kube API (6443) from private LB
#    - Health checks from private subnet

resource "oci_core_network_security_group_security_rule" "cp_ssh_in_from_bastion" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.bastion.id
  # Only allow SSH from bastion NSG
  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cp_api_in_from_privatelb" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.private_lb.id
  # Allow kube-apiserver access from private LB
  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cp_healthcheck_in_from_subnet" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source_type               = "CIDR_BLOCK"
  source                    = var.private_subnet_cidr
  description               = "Allow LB Health Checks from within the private subnet"
  # Health checks for kube-apiserver
  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}


# 3) Workers:
#    - Allow NodePorts (30000-32767) from public LB (TCP & UDP)
#    - Allow SSH from bastion

resource "oci_core_network_security_group_security_rule" "workers_nodeport_tcp_in_from_publiclb" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.public_lb.id
  # NodePort TCP from public LB
  tcp_options {
    destination_port_range {
      min = 30000
      max = 32767
    }
  }
}

resource "oci_core_network_security_group_security_rule" "workers_nodeport_udp_in_from_publiclb" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                 = "INGRESS"
  protocol                  = "17" # UDP
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.public_lb.id
  # NodePort UDP from public LB
  udp_options {
    destination_port_range {
      min = 30000
      max = 32767
    }
  }
}

resource "oci_core_network_security_group_security_rule" "workers_ssh_in_from_bastion" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.bastion.id
  # SSH from bastion only
  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}


# 4a) Public LB: allow HTTPS/HTTP from Cloudflare + Admin IPv4s
resource "oci_core_network_security_group_security_rule" "public_lb_https_ingress" {
  for_each                  = toset(local.public_lb_ingress_cidrs)
  network_security_group_id = oci_core_network_security_group.public_lb.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source_type               = "CIDR_BLOCK"
  source                    = each.value
  # HTTPS ingress for public LB
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

# Public LB: allow HTTP from Cloudflare + Admin IPv4s (ACME/http->https, etc.)
resource "oci_core_network_security_group_security_rule" "public_lb_http_ingress" {
  for_each                  = toset(local.public_lb_ingress_cidrs)
  network_security_group_id = oci_core_network_security_group.public_lb.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source_type               = "CIDR_BLOCK"
  source                    = each.value
  # HTTP ingress for public LB
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
  direction                 = "EGRESS"
  protocol                  = "6"
  destination_type          = "NETWORK_SECURITY_GROUP"
  destination               = oci_core_network_security_group.workers.id
  # Egress to NodePort TCP range
  tcp_options {
    destination_port_range {
      min = 30000
      max = 32767
    }
  }
}

resource "oci_core_network_security_group_security_rule" "public_lb_to_workers_nodeports_egress_udp" {
  network_security_group_id = oci_core_network_security_group.public_lb.id
  direction                 = "EGRESS"
  protocol                  = "17"
  destination_type          = "NETWORK_SECURITY_GROUP"
  destination               = oci_core_network_security_group.workers.id
  # Egress to NodePort UDP range
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
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.workers.id
  # Workers access kube-apiserver via private LB
  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "private_lb_ingress_from_cp_6443" {
  network_security_group_id = oci_core_network_security_group.private_lb.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.control_plane.id
  # Control plane access via private LB
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
  direction                 = "EGRESS"
  protocol                  = "6" # TCP
  destination_type          = "NETWORK_SECURITY_GROUP"
  destination               = oci_core_network_security_group.control_plane.id
  # Egress to kube-apiserver from private LB
  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}


# --- Generic egress (bastion / control-plane / workers) ---
# Allow all outbound traffic for updates, package installs, etc.
resource "oci_core_network_security_group_security_rule" "bastion_egress_all" {
  network_security_group_id = oci_core_network_security_group.bastion.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination_type          = "CIDR_BLOCK"
  destination               = "0.0.0.0/0"
}

resource "oci_core_network_security_group_security_rule" "cp_egress_all" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination_type          = "CIDR_BLOCK"
  destination               = "0.0.0.0/0"
}

resource "oci_core_network_security_group_security_rule" "workers_egress_all" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination_type          = "CIDR_BLOCK"
  destination               = "0.0.0.0/0"
}


# --- Flannel VXLAN (UDP/8472) between all nodes ---
# Allow overlay networking between all control-plane and worker nodes
resource "oci_core_network_security_group_security_rule" "cp_flannel_in_from_cp" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "INGRESS"
  protocol                  = "17" # UDP
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.control_plane.id
  # VXLAN from control-plane
  udp_options {
    destination_port_range {
      min = 8472
      max = 8472
    }
  }
}

resource "oci_core_network_security_group_security_rule" "cp_flannel_in_from_workers" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.workers.id
  # VXLAN from workers
  udp_options {
    destination_port_range {
      min = 8472
      max = 8472
    }
  }
}

resource "oci_core_network_security_group_security_rule" "workers_flannel_in_from_cp" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.control_plane.id
  # VXLAN from control-plane
  udp_options {
    destination_port_range {
      min = 8472
      max = 8472
    }
  }
}

resource "oci_core_network_security_group_security_rule" "workers_flannel_in_from_workers" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.workers.id
  # VXLAN from workers
  udp_options {
    destination_port_range {
      min = 8472
      max = 8472
    }
  }
}


# --- Kubelet (TCP/10250) control-plane -> workers ---
# Allow control-plane to reach kubelet on workers
resource "oci_core_network_security_group_security_rule" "workers_kubelet_in_from_cp" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.control_plane.id
  # Kubelet API
  tcp_options {
    destination_port_range {
      min = 10250
      max = 10250
    }
  }
}


# --- NLB -> Workers: allow Public NLB to reach NGINX NodePort for PostgreSQL traffic (30432) ---
# Special rule for PostgreSQL NodePort via NGINX
resource "oci_core_network_security_group_security_rule" "workers_ingress_from_public_lb_for_postgres_nodeport" {
  network_security_group_id = oci_core_network_security_group.workers.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.public_lb.id
  description               = "Allow Public NLB to reach NGINX NodePort for PostgreSQL traffic"
  # PostgreSQL NodePort
  tcp_options {
    destination_port_range {
      min = 30432
      max = 30432
    }
  }
}
