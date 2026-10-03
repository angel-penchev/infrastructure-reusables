# Builds a NixOS installer ISO from a flake and uploads it to a Proxmox
# storage, for nixos-vm to boot new VMs from. An ISO goes through the Proxmox
# API; a disk image or a backup would need SSH to the node.
#
# A plan only evaluates the ISO's store path; the 1.5 GB build happens at
# apply, when the ISO is first uploaded or `generation` changes. A newer
# flake does not re-upload it on its own: the installer only has to boot a VM
# far enough for nixos-anywhere, which installs what the flake says at that
# moment. Bumping `generation` rebuilds and re-uploads it under the same name,
# so VMs that keep it attached keep a valid reference.

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

resource "terraform_data" "build" {
  triggers_replace = [var.generation]

  provisioner "local-exec" {
    command = "nix --extra-experimental-features 'nix-command flakes' build --no-link '${var.flake_attr}'"
  }
}

resource "proxmox_virtual_environment_file" "iso" {
  content_type = "iso"
  datastore_id = var.datastore_id
  node_name    = var.node_name

  source_file {
    path = "${data.external.iso.result.out}/iso/${var.iso_name}.iso"
  }

  lifecycle {
    ignore_changes       = [source_file]
    replace_triggered_by = [terraform_data.build]
  }

  depends_on = [terraform_data.build]
}
