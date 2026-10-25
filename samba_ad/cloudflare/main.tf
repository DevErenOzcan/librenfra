# ============================================================================
# The admin page from the internet - Cloudflare's side of samba_ad
# ============================================================================
# https://account-manager.deverenozcan.com ─▶ Tunnel "ad-admin" ─▶ cloudflared
# on dc1 ─▶ nginx and LDAP Account Manager on 127.0.0.1:8081 (roles/ad_admin_ui).
#
# A test setup, on purpose without Cloudflare Access: anyone who knows the
# Administrator password can sign in, and Administrator is exempt from AD's
# account lockout. Delete this configuration (terraform destroy) to keep the
# page inside the firewall again.

locals {
  domain     = "deverenozcan.com"
  admin_host = "account-manager.${local.domain}"

  zone_id    = data.cloudflare_zone.domain.zone_id
  account_id = data.cloudflare_zone.domain.account.id
}

data "cloudflare_zone" "domain" {
  filter = {
    name = local.domain
  }
}

# Remotely managed: cloudflared on dc1 needs only the token (output
# tunnel_token, into ../.env as SAMBA_CLOUDFLARED_TOKEN). It dials out.
resource "cloudflare_zero_trust_tunnel_cloudflared" "admin" {
  account_id = local.account_id
  name       = "ad-admin"
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "admin" {
  account_id = local.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.admin.id

  config = {
    ingress = [
      {
        hostname = local.admin_host
        service  = "http://127.0.0.1:8081"
      },
      {
        service = "http_status:404"
      },
    ]
  }
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "admin" {
  account_id = local.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.admin.id
}

resource "cloudflare_dns_record" "admin" {
  zone_id = local.zone_id
  name    = local.admin_host
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.admin.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "Tunnel to the DC's admin page (librenfra samba_ad/cloudflare)"
}
