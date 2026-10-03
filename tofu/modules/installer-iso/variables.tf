variable "flake_attr" {
  type        = string
  description = "Flake output that builds the ISO, e.g. \"/path/to/flake#installer-iso\": a config.system.build.isoImage of a system importing nixosModules.installer."
}

variable "iso_name" {
  type        = string
  description = "The ISO's file name without .iso: servacho.installer.name of the system that builds it."
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

variable "generation" {
  type        = string
  default     = "1"
  description = "Change to rebuild the ISO from the current flake and upload it again under the same name."
}
