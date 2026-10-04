# Builds a NixOS installer ISO from a flake and uploads it to a Proxmox
# storage, for nixos-vm to boot new VMs from. An ISO goes through the Proxmox
# API; a disk image or a backup would need SSH to the node.
#
# The ISO follows the flake: a plan evaluates its store path, which changes
# exactly when anything that goes into it does (nixpkgs, the installer module,
# the keys it lets in). A new store path is built at apply (1.5 GB, mostly
# from the binary cache) and uploaded under a name of its own,
# <iso_name>-<hash>.iso. VMs that have the old one attached are moved onto it
# before the old one is deleted, so none ever points at a missing ISO.

data "external" "iso" {
  program = [
    "nix",
    "--extra-experimental-features",
    "nix-command flakes",
    "eval",
    "--json",
    var.flake_attr,
    "--apply",
    "drv: { out = drv.outPath; }",
  ]
}

locals {
  out = data.external.iso.result.out
  # The store path's hash: short, and different for every build.
  file_name = "${var.iso_name}-${substr(basename(local.out), 0, 8)}.iso"
}

# The upload reads the ISO from the store, so it waits for this build.
resource "terraform_data" "build" {
  input            = local.out
  triggers_replace = [local.out]

  provisioner "local-exec" {
    command = "nix --extra-experimental-features 'nix-command flakes' build --no-link '${var.flake_attr}'"
  }
}

resource "proxmox_virtual_environment_file" "iso" {
  content_type = "iso"
  datastore_id = var.datastore_id
  node_name    = var.node_name

  source_file {
    path      = "${terraform_data.build.output}/iso/${var.iso_name}.iso"
    file_name = local.file_name
  }

  lifecycle {
    create_before_destroy = true
  }
}
