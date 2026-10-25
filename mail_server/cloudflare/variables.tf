variable "cloudflare_api_token" {
  description = "Cloudflare API token (README.md, \"The API token\"). From secret.tfvars (git-ignored): -var-file=secret.tfvars"
  type        = string
  sensitive   = true
}

variable "fallback_address" {
  description = <<-EOT
    Where the Worker forwards a message when the mail server cannot take it
    (down, busy, unreachable), so nothing is lost. Must be a verified
    destination address in Email Routing. A private address, so it lives in
    secret.tfvars, not here.
  EOT
  type        = string
  sensitive   = true
}

variable "test_address" {
  description = <<-EOT
    One address of the domain to send to the mail server, while everything
    else still goes where Email Routing sent it before - for testing the
    whole way with a real sender. Empty: no test rule.
  EOT
  type        = string
  default     = ""
}

variable "route_all_mail" {
  description = <<-EOT
    true: Email Routing's catch-all hands every address of the domain to the
    mail server (README.md, "Switching mail over"). false: the catch-all is
    left as it is.
  EOT
  type        = bool
  default     = false
}
