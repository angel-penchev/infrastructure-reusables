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

variable "gc_root_dir" {
  type        = string
  default     = "/var/lib/opentofu/gcroots"
  description = "A directory that survives between runs, for the garbage collector roots that keep each uploaded ISO's store path; the provider reads that file on every refresh. The default is in the OpenTofu state directory of nixosModules.management-plane's runner."

  validation {
    condition     = startswith(var.gc_root_dir, "/")
    error_message = "gc_root_dir must be an absolute path."
  }
}
