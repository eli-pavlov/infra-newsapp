# K3s token for cluster join authentication
resource "random_password" "k3s_token" {
  length  = 55
  special = false
}

# =================== CONTROL-PLANE cloud-init ===================
# Single-file cloud-init for the k3s server (renders a fully self-contained script)
data "cloudinit_config" "k3s_server_tpl" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    filename     = "/tmp/k3s-install-server.sh"
    content = templatefile("${path.module}/files/k3s-install-server.sh.tftpl", {
      T_K3S_VERSION          = var.k3s_version
      T_K3S_TOKEN            = random_password.k3s_token.result
      T_DB_USER              = var.db_user
      T_DB_NAME_DEV          = var.db_name_dev
      T_DB_NAME_PROD         = var.db_name_prod
      T_DB_SERVICE_NAME_DEV  = var.db_service_name_dev
      T_DB_SERVICE_NAME_PROD = var.db_service_name_prod
      T_MANIFESTS_REPO_URL   = var.manifests_repo_url
      T_EXPECTED_NODE_COUNT  = tostring(local.expected_total_node_count)
      T_PRIVATE_LB_IP        = var.private_lb_ip_address
    })
  }

  # wrapper part to execute the script (cloud-init will drop /tmp/k3s-install-server.sh and then run it)
  part {
    content_type = "text/x-shellscript"
    filename     = "/var/lib/cloud/scripts/per-instance/run-k3s-server.sh"
    content = <<-EOF
      #!/bin/bash
      set -euo pipefail
      # Ensure the rendered script is executable and then run it
      chmod +x /tmp/k3s-install-server.sh
      /tmp/k3s-install-server.sh
    EOF
  }
}

# =================== AGENT cloud-init TEMPLATES (fixed: single-file rendered scripts) ===================
# k3s_agent_app_tpl   (application workers)
# k3s_agent_db_tpl    (database worker)
# Both now render a fully self-contained agent script via templatefile()

data "cloudinit_config" "k3s_agent_app_tpl" {
  gzip          = true
  base64_encode = true

  # Render full agent script (template contains exports + installer logic)
  part {
    content_type = "text/x-shellscript"
    filename     = "/tmp/k3s-install-agent.sh"
    content = templatefile("${path.module}/files/k3s-install-agent.sh.tftpl", {
      T_K3S_VERSION = var.k3s_version
      T_K3S_TOKEN   = random_password.k3s_token.result
      T_K3S_URL_IP  = var.private_lb_ip_address
      T_NODE_LABELS = "role=application"
      T_NODE_TAINTS = ""
    })
  }

  # wrapper to ensure file is executable and then run the rendered script
  part {
    content_type = "text/x-shellscript"
    filename     = "/var/lib/cloud/scripts/per-instance/run-k3s-agent.sh"
    content = <<-EOT
      #!/bin/bash
      set -euo pipefail
      chmod +x /tmp/k3s-install-agent.sh
      /tmp/k3s-install-agent.sh
    EOT
  }
}

data "cloudinit_config" "k3s_agent_db_tpl" {
  gzip          = true
  base64_encode = true

  # Render full agent script (template contains exports + installer logic)
  part {
    content_type = "text/x-shellscript"
    filename     = "/tmp/k3s-install-agent.sh"
    content = templatefile("${path.module}/files/k3s-install-agent.sh.tftpl", {
      T_K3S_VERSION = var.k3s_version
      T_K3S_TOKEN   = random_password.k3s_token.result
      T_K3S_URL_IP  = var.private_lb_ip_address
      T_NODE_LABELS = "role=database"
      T_NODE_TAINTS = "role=database:NoSchedule"
    })
  }

  # wrapper to ensure file is executable and then run the rendered script
  part {
    content_type = "text/x-shellscript"
    filename     = "/var/lib/cloud/scripts/per-instance/run-k3s-agent.sh"
    content = <<-EOT
      #!/bin/bash
      set -euo pipefail
      chmod +x /tmp/k3s-install-agent.sh
      /tmp/k3s-install-agent.sh
    EOT
  }
}

# =================== VNIC lookups for instance IPs ===================

# Control plane
data "oci_core_vnic_attachments" "cp" {
  compartment_id = var.compartment_ocid
  instance_id    = oci_core_instance.control_plane.id
}
data "oci_core_vnic" "cp" {
  vnic_id = data.oci_core_vnic_attachments.cp.vnic_attachments[0].vnic_id
}

# Bastion
data "oci_core_vnic_attachments" "bastion" {
  compartment_id = var.compartment_ocid
  instance_id    = oci_core_instance.bastion.id
}
data "oci_core_vnic" "bastion" {
  vnic_id = data.oci_core_vnic_attachments.bastion.vnic_attachments[0].vnic_id
}

# App workers (map by index)
data "oci_core_vnic_attachments" "app" {
  for_each       = { for idx, inst in oci_core_instance.app_workers : idx => inst.id }
  compartment_id = var.compartment_ocid
  instance_id    = each.value
}
data "oci_core_vnic" "app" {
  for_each = data.oci_core_vnic_attachments.app
  vnic_id  = each.value.vnic_attachments[0].vnic_id
}

# DB worker
data "oci_core_vnic_attachments" "db" {
  compartment_id = var.compartment_ocid
  instance_id    = oci_core_instance.db_worker.id
}
data "oci_core_vnic" "db" {
  vnic_id = data.oci_core_vnic_attachments.db.vnic_attachments[0].vnic_id
}
