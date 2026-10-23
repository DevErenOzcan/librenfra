terraform {
  required_version = ">= 1.5"

  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      # .terraform.lock.hcl pins the exact version.
      version = "~> 0.112"
    }
  }
}

provider "proxmox" {
  endpoint = "https://192.168.1.200:8006/"
  username = "root@pam"
  password = var.proxmox_password
  insecure = true # the host's self-signed certificate
}
