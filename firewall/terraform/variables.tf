variable "proxmox_password" {
  description = "Password of root@pam on the Proxmox host. From secret.tfvars (git-ignored): -var-file=secret.tfvars"
  type        = string
  sensitive   = true
}

variable "installer_iso" {
  description = <<-EOT
    The OPNsense installer, as a volume on the host's "local" storage. It
    stays attached as the CD so a reinstall needs nothing else. Terraform does
    not download it: README.md, "The installer", says how it gets there.
  EOT
  type        = string
  default     = "local:iso/opnsense-26.7-dvd-amd64.iso"
}

variable "wan_connected" {
  description = <<-EOT
    Whether the WAN NIC (net0) is plugged into the home network. true: the
    firewall is installed and its WAN is 192.168.1.201 - false here would
    unplug the running firewall.

    Only a fresh install passes -var wan_connected=false, until the console
    shows WAN on 192.168.1.201 (README.md, "Building it from nothing").
  EOT
  type        = bool
  default     = true
}
