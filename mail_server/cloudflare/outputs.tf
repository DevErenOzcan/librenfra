output "tunnel_token" {
  description = "cloudflared's token; goes into ../.env as MAIL_CLOUDFLARED_TOKEN (README.md, \"Setting it up\")"
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.mail.token
  sensitive   = true
}

output "receiver_url" {
  description = "Where the Worker sends each message"
  value       = "https://${local.inbound_host}/inbound"
}
