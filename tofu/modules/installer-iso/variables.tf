variable "flake_attr" {
  type        = string
  description = "Flake output that builds the ISO, e.g. \"/path/to/flake#installer-iso\": a config.system.build.isoImage of a system importing nixosModules.installer."
}

variable "iso_name" {
  type        = string
  description = "servacho.installer.name of the system that builds it: the ISO's file name in the build without .iso, and the start of its name on the storage."
}

variable "node_name" {
  type        = string
  description = "Proxmox node to upload to."
}

variable "datastore_id" {
  type        = string
  default     = "local"
  description = "Storage that holds ISO images on that node."
}
