variable "cloudflare_api_token" {
  description = "Cloudflare API token, the same one ../../mail_server/cloudflare uses (its README, \"The API token\"). From secret.tfvars (git-ignored): -var-file=secret.tfvars"
  type        = string
  sensitive   = true
}
