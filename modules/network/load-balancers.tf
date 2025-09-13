
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
  timeouts {
    create = "5m"
    update = "5m"
    delete = "5m"
  }
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
  timeouts {
  create = "5m"
  update = "5m"
  delete = "5m"
}
}

resource "oci_load_balancer_backend_set" "private_lb_backendset_api" {
  name             = "k8s_kube_api_backend_set"
  load_balancer_id = oci_load_balancer_load_balancer.private_lb.id
  policy           = "ROUND_ROBIN"
  health_checker {
    protocol = "TCP"
    port     = 6443
  }
}

resource "oci_load_balancer_listener" "private_lb_listener_api" {
  name                       = "k8s_kube_api_listener"
  load_balancer_id           = oci_load_balancer_load_balancer.private_lb.id
  default_backend_set_name   = oci_load_balancer_backend_set.private_lb_backendset_api.name
  port                       = 6443
  protocol                   = "TCP"
}

# --- ADD THIS NEW BACKEND SET AND LISTENER FOR RKE2 ---
resource "oci_load_balancer_backend_set" "private_lb_backendset_registration" {
  name             = "k8s_rke2_reg_backend_set"
  load_balancer_id = oci_load_balancer_load_balancer.private_lb.id
  policy           = "ROUND_ROBIN"
  health_checker {
    protocol = "TCP"
    port     = 9345
  }
}


resource "oci_load_balancer_listener" "private_lb_listener_registration" {
  name                       = "k8s_rke2_registration_listener"
  load_balancer_id           = oci_load_balancer_load_balancer.private_lb.id
  default_backend_set_name   = oci_load_balancer_backend_set.private_lb_backendset_registration.name
  port                       = 9345
  protocol                   = "TCP"
}

resource "null_resource" "wait_public_nlb_active" {
  # trigger this null_resource to re-run if the NLB id changes
  triggers = {
    nlb_id = oci_network_load_balancer_network_load_balancer.public_nlb.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      set -euo pipefail

      # NLB ID coming from the resource above
      NLB_ID="${oci_network_load_balancer_network_load_balancer.public_nlb.id}"

      echo "Waiting for public NLB $NLB_ID to reach ACTIVE (up to 5 minutes)..."
      for i in $(seq 1 60); do
        state=$(oci network-load-balancer network-load-balancer get \
          --network-load-balancer-id "$NLB_ID" \
          --query "data.lifecycle-state" --raw-output 2>/dev/null || echo "ERROR")
        echo "  [attempt $i] state=$state"
        if [ "$state" = "ACTIVE" ]; then
          echo "Public NLB is ACTIVE."
          exit 0
        fi
        sleep 5
      done

      echo "Timed out waiting for public NLB to become ACTIVE."
      exit 1
    EOT
  }
}

# Export a simple boolean output that depends on the waiter
output "public_nlb_ready" {
  value       = true
  description = "True when the public NLB has been verified ACTIVE by the waiter."
  depends_on  = [null_resource.wait_public_nlb_active]
}
