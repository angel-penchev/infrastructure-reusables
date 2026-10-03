output "vm_id" {
  value = proxmox_virtual_environment_vm.this.vm_id
}

output "address" {
  value = var.address
}

output "installation_id" {
  description = "Changes exactly when the VM is installed again. Use it to trigger one-off setup of the installed host."
  value       = local.installation_id
}
