variable "proxmox_password" {
  description = "Password of root@pam on the Proxmox host. From secret.tfvars (git-ignored): -var-file=secret.tfvars"
  type        = string
  sensitive   = true
}

variable "os_image" {
  description = <<-EOT
    The Ubuntu Server 26.04 cloud image the OS disk is imported from: a file
    on the host's "local" storage (content type "import"). Only used when the
    VM is created; the running VM ignores it. README.md, "The disk image",
    says how to put a current build there.
  EOT
  type        = string
  default     = "local:import/ubuntu-26.04-server-cloudimg-amd64.qcow2"
}
