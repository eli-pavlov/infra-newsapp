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
resource "cloudflare_record" "argocd" {
  zone_id = var.cloudflare_zone_id
  name    = "argocd"
  content  = module.network.public_nlb_ip_address
  type    = "A"
  ttl     = 1 # Automatic
  proxied = true
}

# Create A record for newsapp-dev.weblightenment.com
resource "cloudflare_record" "newsapp_dev" {
  zone_id = var.cloudflare_zone_id
  name    = "newsapp-dev"
  content   = module.network.public_nlb_ip_address
  type    = "A"
  ttl     = 1 # Automatic
  proxied = true
}

# Create A record for newsapp.weblightenment.com
resource "cloudflare_record" "newsapp_prod" {
  zone_id = var.cloudflare_zone_id
  name    = "newsapp"
  content   = module.network.public_nlb_ip_address
  type    = "A"
  ttl     = 1 # Automatic
  proxied = true
}