# ============================================================================
# The way in for mail - Cloudflare's side of mail_server
# ============================================================================
# The home connection is behind the ISP's carrier-grade NAT, so the mail
# server cannot be reached from the internet. Cloudflare holds the domain and
# its MX records, and passes mail on:
#
#   Email Routing ─▶ Worker "mail-inbound" ─▶ https://mx-in.deverenozcan.com
#        (Access: the Worker's service token only) ─▶ Tunnel "mail-inbound"
#        ─▶ cloudflared on VM 130 ─▶ the receiver, 127.0.0.1:8025
#
# The same tunnel carries webmail: https://mail.deverenozcan.com ─▶ nginx and
# Roundcube on 127.0.0.1:8080. Cloudflare's own certificate covers it here;
# Let's Encrypt validates the server's certificate through it as well.
#
# Nothing here touches where mail goes until route_all_mail is true (or
# test_address is set): Email Routing keeps doing what it did before.

locals {
  domain = "deverenozcan.com"
  # The tunnel's public hostnames: the receiver, and webmail.
  inbound_host = "mx-in.${local.domain}"
  webmail_host = "mail.${local.domain}"

  zone_id    = data.cloudflare_zone.domain.zone_id
  account_id = data.cloudflare_zone.domain.account.id

  # The receiver's shared secret, from the mail server's own .env, so it is
  # written down once (../.env, MAIL_RECEIVER_SECRET).
  receiver_secret = regex("(?m)^MAIL_RECEIVER_SECRET=(.+)$", file("${path.module}/../.env"))[0]
}

data "cloudflare_zone" "domain" {
  filter = {
    name = local.domain
  }
}

# ---------------------------------------------------------------------------
# The tunnel
# ---------------------------------------------------------------------------
# Remotely managed: its routes are here, and cloudflared on the mail server
# needs only the token (output tunnel_token, into ../.env as
# MAIL_CLOUDFLARED_TOKEN). It dials out; nothing at home listens.
resource "cloudflare_zero_trust_tunnel_cloudflared" "mail" {
  account_id = local.account_id
  name       = "mail-inbound"
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "mail" {
  account_id = local.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.mail.id

  config = {
    ingress = [
      {
        hostname = local.inbound_host
        service  = "http://127.0.0.1:8025"
        # Pass the Worker's Content-Length on rather than re-chunking the
        # body (the receiver reads both, but a length is simpler).
        origin_request = {
          disable_chunked_encoding = true
        }
      },
      # Webmail, and Let's Encrypt's checks for the server's certificate.
      # Not behind Access: Roundcube's own login is the door, as on any
      # webmail (README.md, "Webmail").
      {
        hostname = local.webmail_host
        service  = "http://127.0.0.1:8080"
      },
      # Anything else the tunnel is asked for.
      {
        service = "http_status:404"
      },
    ]
  }
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "mail" {
  account_id = local.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.mail.id
}

resource "cloudflare_dns_record" "inbound" {
  zone_id = local.zone_id
  name    = local.inbound_host
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.mail.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1 # automatic, as for every proxied record
  comment = "Tunnel to the mail server's receiver (librenfra mail_server/cloudflare)"
}

# Public DNS only: inside, the firewall answers mail.deverenozcan.com with the
# server's own address, so LAN clients go to it directly.
resource "cloudflare_dns_record" "webmail" {
  zone_id = local.zone_id
  name    = local.webmail_host
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.mail.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "Tunnel to the mail server's webmail (librenfra mail_server/cloudflare)"
}

# ---------------------------------------------------------------------------
# Access: only the Worker gets through
# ---------------------------------------------------------------------------
# Everything else asking for mx-in is stopped at Cloudflare's edge, before the
# tunnel. The receiver checks its own shared secret behind that as well.
resource "cloudflare_zero_trust_access_service_token" "worker" {
  account_id = local.account_id
  name       = "mail-inbound worker"
  # An expired token would send every message to the fallback address.
  duration = "forever"
}

resource "cloudflare_zero_trust_access_policy" "worker" {
  account_id = local.account_id
  name       = "mail-inbound: the Worker's service token"
  decision   = "non_identity"
  include = [
    {
      service_token = {
        token_id = cloudflare_zero_trust_access_service_token.worker.id
      }
    },
  ]
}

resource "cloudflare_zero_trust_access_application" "inbound" {
  account_id = local.account_id
  name       = "mail-inbound"
  type       = "self_hosted"
  domain     = local.inbound_host
  policies = [
    {
      id         = cloudflare_zero_trust_access_policy.worker.id
      precedence = 1
    },
  ]
}

# ---------------------------------------------------------------------------
# The Worker
# ---------------------------------------------------------------------------
# worker/mail-inbound.js: POSTs each message to the receiver and acts on its
# answer; worker/mail-inbound.test.mjs tests that without Cloudflare.
resource "cloudflare_workers_script" "inbound" {
  account_id         = local.account_id
  script_name        = "mail-inbound"
  content            = file("${path.module}/worker/mail-inbound.js")
  main_module        = "mail-inbound.js"
  compatibility_date = "2026-10-01"

  bindings = [
    {
      name = "RECEIVER_URL"
      type = "plain_text"
      text = "https://${local.inbound_host}/inbound"
    },
    {
      name = "FALLBACK_ADDRESS"
      type = "plain_text"
      text = var.fallback_address
    },
    {
      name = "RECEIVER_SECRET"
      type = "secret_text"
      text = local.receiver_secret
    },
    {
      name = "ACCESS_CLIENT_ID"
      type = "secret_text"
      text = cloudflare_zero_trust_access_service_token.worker.client_id
    },
    {
      name = "ACCESS_CLIENT_SECRET"
      type = "secret_text"
      text = cloudflare_zero_trust_access_service_token.worker.client_secret
    },
  ]

  # Its console.log lines - every fallback - show in the dashboard's logs.
  # Written out as Cloudflare reads them back; with "enabled" alone every
  # plan shows the rest as a change.
  observability = {
    enabled            = true
    head_sampling_rate = 1
    logs = {
      enabled            = true
      head_sampling_rate = 1
      invocation_logs    = true
      persist            = true
    }
    traces = {
      enabled            = false
      head_sampling_rate = 1
      persist            = true
    }
  }
}

# ---------------------------------------------------------------------------
# Email Routing: which mail goes to the Worker
# ---------------------------------------------------------------------------
# One address first, to test the whole way from a real sender
# (var.test_address)...
resource "cloudflare_email_routing_rule" "test" {
  count = var.test_address == "" ? 0 : 1

  zone_id  = local.zone_id
  name     = "mail-inbound test (librenfra)"
  enabled  = true
  priority = 0
  matchers = [
    {
      type  = "literal"
      field = "to"
      value = var.test_address
    },
  ]
  actions = [
    {
      type  = "worker"
      value = [cloudflare_workers_script.inbound.script_name]
    },
  ]
}

# ... then every address of the domain (var.route_all_mail). This replaces
# whatever the catch-all did before; addresses with a rule of their own keep
# it (README.md, "Switching mail over").
resource "cloudflare_email_routing_catch_all" "all" {
  count = var.route_all_mail ? 1 : 0

  zone_id = local.zone_id
  name    = "Every address to the mail server (librenfra)"
  enabled = true
  matchers = [
    {
      type = "all"
    },
  ]
  actions = [
    {
      type  = "worker"
      value = [cloudflare_workers_script.inbound.script_name]
    },
  ]
}
