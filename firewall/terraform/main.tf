# ============================================================================
# opnsense-fw - VM 100, the firewall every internal segment routes through
# ============================================================================
# Router on a stick: the host has one wired NIC, so the WAN leg sits on the
# home network (vmbr0) and LAN, DMZ and LAB are port-less bridges that exist
# only inside the host (vmbr1-vmbr3, created by ProxmoxHomeLab/host). The
# policy itself is applied over OPNsense's API by ../site.yml.
#
# Every value mirrors VM 100 as it runs (/etc/pve/qemu-server/100.conf,
# 2026-10-22), so a plan against the running firewall shows no changes.
resource "proxmox_virtual_environment_vm" "firewall" {
  name        = "opnsense-fw"
  node_name   = "proxmox"
  vm_id       = 100
  description = "OPNsense firewall. WAN on vmbr0; LAN/DMZ/LAB on vmbr1/vmbr2/vmbr3. Managed by Terraform."
  tags        = ["firewall", "opnsense", "terraform"]

  started = true
  on_boot = true

  # First, and 45 seconds ahead of everything else: no guest should boot into
  # a network without a gateway.
  startup {
    order    = 1
    up_delay = 45
  }

  # 'host' hands AES-NI to FreeBSD. A single node never live-migrates, so
  # there is no reason for a generic CPU model.
  cpu {
    cores   = 2
    sockets = 1
    type    = "host"
  }

  # Enough for a plain router. Raise it to 8 GB before turning on Zenarmor,
  # Suricata and Insight together.
  memory {
    dedicated = 2048
  }

  scsi_hardware = "virtio-scsi-single"

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 40
    iothread     = true
    discard      = "on"
  }

  # The installer stays attached: OPNsense upgrades in place, and a reinstall
  # is then a matter of the console. The slot is pinned because boot_order
  # names it; left to the provider it picked ide3 once, and the CD booted
  # first. Only used when the VM is created (ignore_changes below).
  cdrom {
    file_id   = var.installer_iso
    interface = "ide2"
  }

  # Disk first, CD second. An empty disk has no boot sector, so SeaBIOS falls
  # through to the CD for the first install; afterwards the disk wins.
  boot_order = ["scsi0", "ide2"]

  # The NIC order IS the interface assignment: Proxmox's net0-net3 are
  # FreeBSD's vtnet0-vtnet3, and OPNsense assigns WAN, LAN, OPT1 and OPT2 by
  # those names. Appending a NIC is safe; reordering these blocks rewires a
  # running firewall. The MACs are pinned so a rebuilt VM shows OPNsense the
  # same hardware.
  #
  # The Proxmox firewall is off at datacenter level, so firewall = true would
  # only add the fwbr/fwpr/fwln detour on the host without filtering anything.

  # net0 -> vtnet0 -> WAN, the home network, 192.168.1.201. Unplugged on a
  # fresh install (var.wan_connected): a new OPNsense comes up as LAN
  # 192.168.1.1/24 with a DHCP server, and on vmbr0 it would answer for the
  # home router and hand out leases - the whole house went offline that way on
  # 2026-09-09.
  network_device {
    bridge       = "vmbr0"
    model        = "virtio"
    mac_address  = "02:7A:AA:5D:AD:51"
    firewall     = false
    disconnected = !var.wan_connected
  }

  # net1 -> vtnet1 -> LAN, 10.10.10.1: the trusted guests.
  network_device {
    bridge      = "vmbr1"
    model       = "virtio"
    mac_address = "BC:24:11:40:72:AD"
    firewall    = false
  }

  # net2 -> vtnet2 -> OPT1, the DMZ, 10.10.20.1: services that face the
  # internet.
  network_device {
    bridge      = "vmbr2"
    model       = "virtio"
    mac_address = "BC:24:11:97:40:B5"
    firewall    = false
  }

  # net3 -> vtnet3 -> OPT2, the LAB, 10.10.30.1: experiments and quarantine.
  network_device {
    bridge      = "vmbr3"
    model       = "virtio"
    mac_address = "BC:24:11:46:18:20"
    firewall    = false
  }

  # No operating_system and no agent block: the provider's defaults are what
  # this VM needs, and it reads a default back as absent, so writing them out
  # shows as a change on every plan. They are:
  #   * operating_system "other" - FreeBSD
  #   * agent off - OPNsense ships qemu-guest-agent switched off, and an
  #     agent claimed here would make every apply wait for one that never
  #     answers

  lifecycle {
    ignore_changes = [
      # The provider reads the CD only from the slot already in its state, so
      # an imported VM never shows one. The installer only matters at
      # creation; change it on the host (qm set 100 --ide2 ...) if ever.
      cdrom,
    ]
  }
}
