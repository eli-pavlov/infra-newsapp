# Define variables for Cloudflare credentials
variable "cloudflare_api_token" {
  description = "Cloudflare API Token for managing DNS."
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID for the domain."
  type        = string
  sensitive   = true
}

# Create A record for argocd.weblightenment.com
resource "cloudflare_dns_record" "argocd" {
  zone_id = var.cloudflare_zone_id
  name    = "argocd"
  content   = module.network.public_nlb_ip_address
  type    = "A"
  ttl     = 1 # Automatic
  proxied = true
}
variable "cloudflare_argocd_ruleset_action" {
  description = "Cloudflare ruleset action for requests to argocd_host not from admin CIDRs"
  type        = string
  default     = "challenge"
}

locals {
  # join admin CIDRs into a Cloudflare set literal: "1.2.3.4/32 5.6.0.0/24"
  admin_cidrs_set = join(" ", var.admin_cidrs)

  # Cloudflare expression: match requests to the host and not from any admin CIDR
  argocd_expr = format("(http.host == \"%s\" and not ip.src in {%s})", var.argocd_host, local.admin_cidrs_set)
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
  content   = module.network.public_nlb_ip_address
  type    = "A"
  ttl     = 1 # Automatic
  proxied = true
}

# Create A record for newsapp.weblightenment.com
resource "cloudflare_dns_record" "newsapp_prod" {
  zone_id = var.cloudflare_zone_id
  name    = "newsapp"
  content   = module.network.public_nlb_ip_address
  type    = "A"
  ttl     = 1 # Automatic
  proxied = true
}