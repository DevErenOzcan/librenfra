# Adopts the running firewall into an empty state instead of creating a new
# one: the first plan reads it from the Proxmox API, and the apply records it.
# Once it is in the state this block does nothing.
#
# Building from nothing, with no VM 100 on the host, delete this file first:
# an import of a VM that does not exist fails the plan.
import {
  to = proxmox_virtual_environment_vm.firewall
  id = "proxmox/100"
}
