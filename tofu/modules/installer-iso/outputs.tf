output "file_id" {
  description = "The uploaded ISO's volume id, for nixos-vm's installer_iso_id."
  value       = proxmox_virtual_environment_file.iso.id
}
