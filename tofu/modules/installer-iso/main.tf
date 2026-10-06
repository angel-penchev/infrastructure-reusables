# Builds a NixOS installer ISO from a flake and uploads it to a Proxmox
# storage, for nixos-vm to boot new VMs from. An ISO goes through the Proxmox
# API; a disk image or a backup would need SSH to the node.
#
# The ISO follows the flake: its store path changes exactly when anything that
# goes into it does (nixpkgs, the installer module, the keys it lets in), and a
# new one is uploaded under a name of its own, <iso_name>-<hash>.iso. VMs that
# have the old one attached are moved onto it before the old one is deleted,
# so none ever points at a missing ISO.
#
# The provider reads the uploaded ISO's local file on every refresh, so that
# file has to outlive the Nix garbage collector: a plan realises the ISO
# (building it, 1.5 GB, only when it is new or was collected), and every
# uploaded build keeps a garbage collector root in gc_root_dir until it has
# been replaced.

data "external" "iso" {
  program = [
    "sh",
    "-c",
    "out=$(nix --extra-experimental-features 'nix-command flakes' build --no-link --print-out-paths \"$1\") && printf '{\"out\":\"%s\"}' \"$out\"",
    "realise-installer-iso",
    var.flake_attr,
  ]
}

locals {
  out = data.external.iso.result.out
  # The store path's hash: short, and different for every build.
  file_name = "${var.iso_name}-${substr(basename(local.out), 0, 8)}.iso"
}

# The uploaded build's garbage collector root, removed once a newer build has
# replaced it.
resource "terraform_data" "gc_root" {
  input = {
    out  = local.out
    link = "${var.gc_root_dir}/${trimsuffix(local.file_name, ".iso")}"
  }
  triggers_replace = [local.out]

  provisioner "local-exec" {
    command = "mkdir -p \"$(dirname \"$LINK\")\" && nix-store --realise \"$OUT\" --add-root \"$LINK\" >/dev/null"
    environment = {
      OUT  = self.input.out
      LINK = self.input.link
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = "rm -f \"$LINK\""
    environment = {
      LINK = self.input.link
    }
  }
}

resource "proxmox_virtual_environment_file" "iso" {
  content_type = "iso"
  datastore_id = var.datastore_id
  node_name    = var.node_name

  source_file {
    path      = "${local.out}/iso/${var.iso_name}.iso"
    file_name = local.file_name
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [terraform_data.gc_root]
}
