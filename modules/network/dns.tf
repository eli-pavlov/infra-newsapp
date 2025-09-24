locals {
  # join admin CIDRs into a Cloudflare set literal: "1.2.3.4/32 5.6.0.0/24"
  admin_cidrs_set = join(" ", var.admin_cidrs)

  # protected hosts: quoted and space-separated: "\"host1\" \"host2\""
  protected_hosts_quoted = join(" ", [for h in var.protected_hosts : format("\"%s\"", h)])

  # Cloudflare expression — both sets are space-separated (no commas).
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

resource "cloudflare_ruleset" "admin_access_only" {
  zone_id     = var.cloudflare_zone_id
  name        = "admin-access-only"
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
    },
    {
      description = "Block non-Israel traffic to newsapp hosts"
      expression  = "(http.host in {\"newsapp.weblightenment.com\" \"newsapp-dev.weblightenment.com\"} and ip.geoip.country ne \"IL\")"
      action      = "block"
      enabled     = true
      ref         = "newsapp-israel-only-rule"
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

resource "cloudflare_dns_record" "pgadmin_dev" {
  zone_id = var.cloudflare_zone_id
  name    = "pgadmin-dev"
  content = oci_network_load_balancer_network_load_balancer.public_nlb.ip_addresses[0].ip_address
  type    = "A"
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "grafana" {
  zone_id = var.cloudflare_zone_id
  name    = "grafana"
  content = oci_network_load_balancer_network_load_balancer.public_nlb.ip_addresses[0].ip_address
  type    = "A"
  ttl     = 1
  proxied = true
}