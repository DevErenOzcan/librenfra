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
    mail server - the way it runs since 2026-10-25 (README.md, "Switching
    mail over"). false: Terraform removes its catch-all rule; only for
    setting things up again from nothing, or going back.
  EOT
  type        = bool
  default     = true
}

variable "forward_to_fallback" {
  description = <<-EOT
    Addresses of the domain that Email Routing forwards straight to the
    fallback address (the owner's own mailbox elsewhere) and that never reach
    the mail server. A rule for an address wins over the catch-all.
  EOT
  type        = list(string)
  default     = ["eren.ozcan@deverenozcan.com"]
}
