locals {
  # join admin CIDRs into a Cloudflare set literal: "1.2.3.4/32 5.6.0.0/24"
  admin_cidrs_set = join(" ", var.admin_cidrs)

  # protected hosts: use a var list so you can add more hosts later
  protected_hosts_quoted = join(", ", [for h in var.protected_hosts : format("\"%s\"", h)])

  # Cloudflare expression: match requests to any protected host and not from any admin CIDR
  argocd_expr = format("(http.host in {%s} and not ip.src in {%s})", local.protected_hosts_quoted, local.admin_cidrs_set)
}


# Create A record for argocd.weblightenment.com
resource "cloudflare_dns_record" "argocd" {
  zone_id = var.cloudflare_zone_id
  name    = "argocd"
  content = oci_network_load_balancer_network_load_balancer.public_nlb.ip_addresses[0].ip_address
  type    = "A"
  ttl     = 1 # Automatic
  proxied = true
}

resource "cloudflare_ruleset" "argocd_admin_only" {
  zone_id     = var.cloudflare_zone_id
  name        = "argocd-admin-only"
  kind        = "zone"
  phase       = "http_request_firewall_custom"
  description = "Challenge/block requests to argocd host that do not originate from admin CIDRs."
  rules = [
    {
      description = "Block/Challenge non-admin access to ArgoCD host"
      expression  = local.argocd_expr
      action      = var.cloudflare_argocd_ruleset_action  # challenge | block
      enabled     = true
      ref         = "argocd-admin-only-rule"
    }
  ]
}


# Create A record for newsapp-dev.weblightenment.com
resource "cloudflare_dns_record" "newsapp_dev" {
  zone_id = var.cloudflare_zone_id
  name    = "newsapp-dev"
  content = oci_network_load_balancer_network_load_balancer.public_nlb.ip_addresses[0].ip_address
  type    = "A"
  ttl     = 1 # Automatic
  proxied = true
}


# Create A record for newsapp.weblightenment.com
resource "cloudflare_dns_record" "newsapp_prod" {
  zone_id = var.cloudflare_zone_id
  name    = "newsapp"
  content = oci_network_load_balancer_network_load_balancer.public_nlb.ip_addresses[0].ip_address
  type    = "A"
  ttl     = 1 # Automatic
  proxied = true
}

resource "cloudflare_dns_record" "newsapp_db_dev" {
  zone_id = var.cloudflare_zone_id
  name    = "dbdev"
  content = oci_network_load_balancer_network_load_balancer.public_nlb.ip_addresses[0].ip_address
  type    = "A"
  ttl     = 1 # Automatic
  proxied = false
}

resource "cloudflare_dns_record" "newsapp_db_prod" {
  zone_id = var.cloudflare_zone_id
  name    = "dbprod"
  content   = module.network.public_nlb_ip_address
  type    = "A"
  ttl     = 1 # Automatic
  proxied = false
}