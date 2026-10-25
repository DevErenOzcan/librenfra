output "tunnel_token" {
  description = "cloudflared's token on dc1; goes into ../.env as SAMBA_CLOUDFLARED_TOKEN"
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.admin.token
  sensitive   = true
}

output "admin_url" {
  description = "The admin page from anywhere"
  value       = "https://${local.admin_host}/"
}
