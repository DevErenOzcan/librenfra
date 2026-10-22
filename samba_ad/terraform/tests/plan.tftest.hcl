# A plan against a mock provider: checks what Terraform would create without
# a Proxmox host, a password or a state. From terraform/:
#   terraform init && terraform test

mock_provider "proxmox" {}

variables {
  proxmox_password = "not-used-by-the-mock"
}

run "plans_the_dc_and_its_data_disk" {
  command = plan

  assert {
    condition     = proxmox_virtual_environment_vm.dc.vm_id == 120 && proxmox_virtual_environment_vm.dc.name == "dc1"
    error_message = "The DC must be VM 120 named dc1 (its hostname, samba_ad_hostname)."
  }

  assert {
    condition     = proxmox_virtual_environment_vm.dc.network_device[0].bridge == "vmbr1"
    error_message = "The DC belongs on the LAN, vmbr1."
  }

  assert {
    condition = (
      proxmox_virtual_environment_vm.dc.initialization[0].ip_config[0].ipv4[0].address == "10.10.10.10/24" &&
      proxmox_virtual_environment_vm.dc.initialization[0].ip_config[0].ipv4[0].gateway == "10.10.10.1"
    )
    error_message = "cloud-init must give the DC 10.10.10.10/24 via the firewall's LAN address."
  }

  assert {
    condition     = proxmox_virtual_environment_vm.dc.disk[0].import_from == "local:import/ubuntu-26.04-server-cloudimg-amd64.qcow2"
    error_message = "The OS disk comes from the Ubuntu 26.04 cloud image on the host."
  }

  # The DC attaches exactly the holder's disk, at the holder's size.
  assert {
    condition = (
      proxmox_virtual_environment_vm.dc.disk[1].interface == "scsi1" &&
      proxmox_virtual_environment_vm.dc.disk[1].datastore_id == proxmox_virtual_environment_vm.data_disk.disk[0].datastore_id &&
      proxmox_virtual_environment_vm.dc.disk[1].path_in_datastore == "vm-${proxmox_virtual_environment_vm.data_disk.vm_id}-disk-0" &&
      proxmox_virtual_environment_vm.dc.disk[1].size == proxmox_virtual_environment_vm.data_disk.disk[0].size
    )
    error_message = "scsi1 must be the holder's disk, vmdata:vm-9120-disk-0, at its size."
  }

  assert {
    condition = (
      proxmox_virtual_environment_vm.data_disk.vm_id == 9120 &&
      proxmox_virtual_environment_vm.data_disk.disk[0].size == 10 &&
      proxmox_virtual_environment_vm.data_disk.protection &&
      !proxmox_virtual_environment_vm.data_disk.started &&
      !proxmox_virtual_environment_vm.data_disk.on_boot
    )
    error_message = "The holder is VM 9120 with a 10 GB disk, protected and never started."
  }
}
