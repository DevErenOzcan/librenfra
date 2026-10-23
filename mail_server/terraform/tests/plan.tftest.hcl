# A plan against a mock provider: checks what Terraform would create without
# a Proxmox host, a password or a state. From terraform/:
#   terraform init && terraform test

mock_provider "proxmox" {}

variables {
  proxmox_password = "not-used-by-the-mock"
}

run "plans_the_mail_server_and_its_data_disk" {
  command = plan

  assert {
    condition     = proxmox_virtual_environment_vm.mail.vm_id == 130 && proxmox_virtual_environment_vm.mail.name == "mail"
    error_message = "The mail server must be VM 130 named mail (its hostname)."
  }

  assert {
    condition     = proxmox_virtual_environment_vm.mail.network_device[0].bridge == "vmbr2"
    error_message = "The mail server belongs in the DMZ, vmbr2."
  }

  assert {
    condition = (
      proxmox_virtual_environment_vm.mail.initialization[0].ip_config[0].ipv4[0].address == "10.10.20.10/24" &&
      proxmox_virtual_environment_vm.mail.initialization[0].ip_config[0].ipv4[0].gateway == "10.10.20.1" &&
      proxmox_virtual_environment_vm.mail.initialization[0].dns[0].domain == "deverenozcan.com"
    )
    error_message = "cloud-init must give the mail server 10.10.20.10/24 via the firewall's DMZ address, in deverenozcan.com."
  }

  assert {
    condition     = proxmox_virtual_environment_vm.mail.disk[0].import_from == "local:import/ubuntu-26.04-server-cloudimg-amd64.qcow2"
    error_message = "The OS disk comes from the Ubuntu 26.04 cloud image on the host."
  }

  # The mail server attaches exactly the holder's disk, at the holder's size.
  assert {
    condition = (
      proxmox_virtual_environment_vm.mail.disk[1].interface == "scsi1" &&
      proxmox_virtual_environment_vm.mail.disk[1].datastore_id == proxmox_virtual_environment_vm.data_disk.disk[0].datastore_id &&
      proxmox_virtual_environment_vm.mail.disk[1].path_in_datastore == "vm-${proxmox_virtual_environment_vm.data_disk.vm_id}-disk-0" &&
      proxmox_virtual_environment_vm.mail.disk[1].size == proxmox_virtual_environment_vm.data_disk.disk[0].size
    )
    error_message = "scsi1 must be the holder's disk, vmdata:vm-9130-disk-0, at its size."
  }

  assert {
    condition = (
      proxmox_virtual_environment_vm.data_disk.vm_id == 9130 &&
      proxmox_virtual_environment_vm.data_disk.disk[0].size == 40 &&
      proxmox_virtual_environment_vm.data_disk.protection &&
      !proxmox_virtual_environment_vm.data_disk.started &&
      !proxmox_virtual_environment_vm.data_disk.on_boot
    )
    error_message = "The holder is VM 9130 with a 40 GB disk, protected and never started."
  }
}
