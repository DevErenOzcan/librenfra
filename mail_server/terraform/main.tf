# ============================================================================
# mail - VM 130, the organisation's mail server, and VM 9130 that holds its
# data disk
# ============================================================================
# An Ubuntu Server 26.04 cloud image in the DMZ (vmbr2) at 10.10.20.10, an
# address cloud-init sets; the DMZ has no DHCP. Ansible (../site.yml) turns it
# into the mail server of deverenozcan.com: Postfix, Dovecot and rspamd, with
# the accounts in Active Directory, and mail from the internet arriving
# through Cloudflare (README.md, "How mail gets in").
#
# The firewall (../../firewall) has to be running: it is the gateway and the
# DNS server, and it lets this VM reach the domain controller over LDAPS.

# ---------------------------------------------------------------------------
# The data disk - VM 9130, which is never started
# ---------------------------------------------------------------------------
# The mailboxes live on it (/var/vmail), with rspamd's and Redis's state. A
# rebuilt VM gets them back.
#
# Proxmox deletes a VM's own disks together with the VM, but skips a disk that
# belongs to another VM ID. So the disk belongs to this holder, VM 9130, and
# VM 130 only attaches it (scsi1 below): VM 130 can be destroyed and rebuilt,
# and the mail stays.
#
# Never start this VM, and never move or resize its disk through it. Two VMs
# running on one disk corrupt it.
resource "proxmox_virtual_environment_vm" "data_disk" {
  name        = "data-130"
  node_name   = "proxmox"
  vm_id       = 9130
  description = "Holds a persistent data disk for VM 130. Never started. Managed by Terraform."
  tags        = ["data-disk", "terraform"]

  started = false
  on_boot = false

  # Proxmox refuses to remove a protected VM or its disks, from the GUI too.
  protection = true

  # On "vmdata", the host's second NVMe as thick LVM (ProxmoxHomeLab/host):
  # 40 GB reserved in full. The size must not change afterwards.
  disk {
    datastore_id = "vmdata"
    interface    = "scsi0"
    size         = 40
    file_format  = "raw"
  }

  lifecycle {
    # Destroying the holder destroys every mailbox. Turn protection off and
    # remove this line first, deliberately, if that is ever what you want.
    prevent_destroy = true

    # VM 130 names the volume before it exists (scsi1 below). Proxmox gives a
    # new VM's first disk exactly this name; if it ever did not, stop here.
    postcondition {
      condition     = self.disk[0].path_in_datastore == "vm-9130-disk-0"
      error_message = "The holder's disk is ${self.disk[0].path_in_datastore}, not vm-9130-disk-0, which VM 130 attaches."
    }
  }
}

# ---------------------------------------------------------------------------
# The mail server - VM 130
# ---------------------------------------------------------------------------
# Headless: cloud images log to the serial console, and the Proxmox console
# shows it (xterm.js). No guest agent - the image does not ship one, and with
# the agent on, the provider waits for it on every create.
resource "proxmox_virtual_environment_vm" "mail" {
  # Also the guest's hostname (cloud-init); with the DNS domain below its
  # FQDN is mail.deverenozcan.com.
  name        = "mail"
  node_name   = "proxmox"
  vm_id       = 130
  description = "Mail server for deverenozcan.com: Postfix, Dovecot, rspamd. Managed by Terraform."
  tags        = ["ubuntu", "mail", "dmz", "terraform"]

  started = true
  on_boot = true

  # After the firewall (order 1, which holds the next guest back 45 s).
  startup {
    order = 2
  }

  cpu {
    cores   = 2
    sockets = 1
    type    = "host"
  }

  # Postfix and Dovecot need little; rspamd and Redis take most of it.
  memory {
    dedicated = 3072
  }

  serial_device {
    device = "socket"
  }

  vga {
    type = "serial0"
  }

  scsi_hardware = "virtio-scsi-single"

  # The OS disk: disposable, imported from the cloud image when the VM is
  # created and grown to 20 GB on first boot.
  disk {
    datastore_id = "local-lvm"
    import_from  = var.os_image
    interface    = "scsi0"
    size         = 20
    iothread     = true
    discard      = "on"
  }

  # The persistent disk, VM 9130's. The guest finds it by its SCSI path and
  # its label (../roles/data_volume).
  disk {
    datastore_id      = "vmdata"
    path_in_datastore = "vm-9130-disk-0"
    file_format       = "raw"
    size              = 40
    interface         = "scsi1"
    iothread          = true
    discard           = "on"
  }

  boot_order = ["scsi0"]

  # cloud-init: the address, the gateway and DNS server (the firewall's DMZ
  # address), the domain that makes the FQDN, and the key of the "ubuntu"
  # user, which has no password and passwordless sudo.
  initialization {
    datastore_id = "local-lvm"

    ip_config {
      ipv4 {
        address = "10.10.20.10/24"
        gateway = "10.10.20.1"
      }
    }

    dns {
      domain  = "deverenozcan.com"
      servers = ["10.10.20.1"]
    }

    user_account {
      username = "ubuntu"
      # The controller's key (ubuntu-desktop, ~/.ssh/id_ed25519.pub).
      keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJrgb4sc8ZVmeUkPyP/I4a2aZ7U4khSq4ePA7ivv5+qV controller-ubuntu-desktop"]
    }
  }

  network_device {
    bridge = "vmbr2"
    model  = "virtio"
    # The Proxmox firewall is off at datacenter level, so true would only add
    # the fwbr/fwpr/fwln detour on the host without filtering anything.
    firewall = false
  }

  operating_system {
    type = "l26"
  }

  depends_on = [proxmox_virtual_environment_vm.data_disk]

  lifecycle {
    # The image only matters at creation, and the API does not report it.
    # Without this a newer image would plan to replace the running server.
    ignore_changes = [disk[0].import_from]
  }
}
