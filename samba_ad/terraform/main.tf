# ============================================================================
# dc1 - VM 120, the Samba AD domain controller, and VM 9120 that holds its
# data disk
# ============================================================================
# An Ubuntu Server 26.04 cloud image on the LAN (vmbr1) at 10.10.10.10, an
# address cloud-init sets - outside the LAN's DHCP pool (.100-.245). Ansible
# (../site.yml) turns it into the domain controller of ad.deverenozcan.com.
#
# The firewall (../../firewall) has to be running: it is the DC's gateway and
# its DNS server until Samba answers for itself.

# ---------------------------------------------------------------------------
# The data disk - VM 9120, which is never started
# ---------------------------------------------------------------------------
# The domain lives on it: /var/lib/samba, with the directory database, SYSVOL
# and the domain's keys. A DC rebuilt without it would be a NEW domain, with a
# new SID, and every machine joined to the old one would fall out of it.
#
# Proxmox deletes a VM's own disks together with the VM, but skips a disk that
# belongs to another VM ID. So the disk belongs to this holder, VM 9120, and
# VM 120 only attaches it (scsi1 below): VM 120 can be destroyed and rebuilt,
# and the domain stays.
#
# Never start this VM, and never move or resize its disk through it. Two VMs
# running on one disk corrupt it.
resource "proxmox_virtual_environment_vm" "data_disk" {
  name        = "data-120"
  node_name   = "proxmox"
  vm_id       = 9120
  description = "Holds a persistent data disk for VM 120. Never started. Managed by Terraform."
  tags        = ["data-disk", "terraform"]

  started = false
  on_boot = false

  # Proxmox refuses to remove a protected VM or its disks, from the GUI too.
  protection = true

  # On "vmdata", the host's second NVMe as thick LVM (ProxmoxHomeLab/host):
  # 10 GB reserved in full. A small organisation's directory stays far below
  # that. The size must not change afterwards.
  disk {
    datastore_id = "vmdata"
    interface    = "scsi0"
    size         = 10
    file_format  = "raw"
  }

  lifecycle {
    # Destroying the holder destroys the domain. Turn protection off and
    # remove this line first, deliberately, if that is ever what you want.
    prevent_destroy = true

    # VM 120 names the volume before it exists (scsi1 below). Proxmox gives a
    # new VM's first disk exactly this name; if it ever did not, stop here.
    postcondition {
      condition     = self.disk[0].path_in_datastore == "vm-9120-disk-0"
      error_message = "The holder's disk is ${self.disk[0].path_in_datastore}, not vm-9120-disk-0, which VM 120 attaches."
    }
  }
}

# ---------------------------------------------------------------------------
# The domain controller - VM 120
# ---------------------------------------------------------------------------
# Headless: cloud images log to the serial console, and the Proxmox console
# shows it (xterm.js). No guest agent - the image does not ship one, and with
# the agent on, the provider waits for it on every create.
resource "proxmox_virtual_environment_vm" "dc" {
  # Also the guest's hostname (cloud-init), the first label of its FQDN and
  # its NetBIOS name: samba_ad_hostname in ../host_vars/dc1.yml.
  name        = "dc1"
  node_name   = "proxmox"
  vm_id       = 120
  description = "Samba Active Directory domain controller for ad.deverenozcan.com. Managed by Terraform."
  tags        = ["ubuntu", "samba", "ad", "terraform"]

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

  # A Samba DC for a small organisation idles well under 1 GB.
  memory {
    dedicated = 2048
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

  # The persistent disk, VM 9120's. The guest finds it by its SCSI path and
  # its label (../roles/data_volume).
  disk {
    datastore_id      = "vmdata"
    path_in_datastore = "vm-9120-disk-0"
    file_format       = "raw"
    size              = 10
    interface         = "scsi1"
    iothread          = true
    discard           = "on"
  }

  boot_order = ["scsi0"]

  # cloud-init: the address, the gateway and DNS server (the firewall's LAN
  # address, until Ansible points the DC at itself), and the key of the
  # "ubuntu" user, which has no password and passwordless sudo.
  initialization {
    datastore_id = "local-lvm"

    ip_config {
      ipv4 {
        address = "10.10.10.10/24"
        gateway = "10.10.10.1"
      }
    }

    dns {
      servers = ["10.10.10.1"]
    }

    user_account {
      username = "ubuntu"
      # The controller's key (ubuntu-desktop, ~/.ssh/id_ed25519.pub).
      keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJrgb4sc8ZVmeUkPyP/I4a2aZ7U4khSq4ePA7ivv5+qV controller-ubuntu-desktop"]
    }
  }

  network_device {
    bridge = "vmbr1"
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
    # Without this a newer image would plan to replace the running DC.
    ignore_changes = [disk[0].import_from]
  }
}
