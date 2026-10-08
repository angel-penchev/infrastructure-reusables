variable "name" {
  type        = string
  description = "VM name."
}

variable "node_name" {
  type        = string
  description = "Proxmox node the VM runs on."
}

variable "vm_id" {
  type        = number
  description = "Proxmox VM id."
}

variable "pool_id" {
  type        = string
  default     = null
  description = "Resource pool the VM belongs to."
}

variable "tags" {
  type        = list(string)
  default     = []
  description = "Proxmox tags."
}

variable "bridge" {
  type        = string
  default     = "vmbr0"
  description = "Bridge the VM's one network interface is on."
}

variable "vlan_id" {
  type        = number
  default     = null
  description = "VLAN tag of that interface; null for untagged."
}

variable "cores" {
  type    = number
  default = 2
}

variable "cpu_type" {
  type    = string
  default = "x86-64-v2-AES"
}

variable "memory" {
  type        = number
  default     = 4096
  description = "MiB."
}

variable "disk_size" {
  type        = number
  default     = 32
  description = "GiB."
}

variable "data_disks" {
  type = list(object({
    size   = number
    backup = optional(bool, true)
  }))
  default     = []
  description = "Disks after the system disk, in order: /dev/vdb onwards on the host, which mounts them through nixosModules.proxmox-guest's dataDisks. size is in GiB; backup = false keeps a disk out of Proxmox backups (say, one whose data is replicated or backed up inside the VM)."
}

variable "datastore_id" {
  type        = string
  default     = "local-lvm"
  description = "Storage for the VM's disk."
}

variable "on_boot" {
  type    = bool
  default = true
}

variable "installer_iso_id" {
  type        = string
  description = "Volume id of the installer ISO, from installer-iso's file_id. Its root must accept ssh_private_key."
}

variable "flake" {
  type        = string
  description = "Absolute path of the flake holding the host configuration."
}

variable "host" {
  type        = string
  description = "Name under the flake's nixosConfigurations. It must import nixosModules.proxmox-guest and give the host the static address below."
}

variable "address" {
  type        = string
  description = "The host's static address once installed: where it is deployed to."
}

variable "ssh_private_key" {
  type        = string
  sensitive   = true
  description = "Private key that root on the installer and on the host accepts."
}

variable "extra_files" {
  type        = map(string)
  default     = {}
  sensitive   = true
  description = "Files placed on the host at install, by absolute path: what the host's configuration must not contain, such as a k3s cluster token. Only the install writes them; later changes reach an installed host only through a reinstall. Files are 0600 root, directories 0755."

  validation {
    condition     = alltrue([for path in keys(var.extra_files) : startswith(path, "/") && !strcontains(path, "..")])
    error_message = "extra_files keys are absolute paths without '..'."
  }
}
