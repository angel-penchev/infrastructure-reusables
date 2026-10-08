# A NixOS VM on Proxmox, from an empty disk to a deployed host, with nothing
# run by hand on the node or the VM:
#
#   1. the VM boots the installer ISO (installer-iso) from an empty disk, takes
#      a DHCP address and reports it through the QEMU guest agent;
#   2. nixos-anywhere partitions the disk with the host's disko layout
#      (nixosModules.proxmox-guest), installs the host and reboots;
#   3. the host comes up on its static address, where every later change to
#      its configuration is deployed in place.
#
# The install runs once per VM that OpenTofu creates: a VM it replaces is
# installed again, while one restored from a backup outside OpenTofu (any MAC,
# same id) keeps its disk.

locals {
  # Where the installer can be reached: an address it got by DHCP, as the
  # guest agent reports it. Loopback and IPv4 link-local are not.
  installer_addresses = [
    for ip in flatten(proxmox_virtual_environment_vm.this.ipv4_addresses) : ip
    if !startswith(ip, "127.") && !startswith(ip, "169.254.")
  ]

  installation_id = terraform_data.installation.id
}

# One per VM OpenTofu creates. Nothing Proxmox can change about the VM (its MAC
# after a restore, its configuration) replaces it; a deliberate reinstall is
# `tofu apply -replace=<this module>.terraform_data.installation`.
resource "terraform_data" "installation" {
  input = proxmox_virtual_environment_vm.this.vm_id

  lifecycle {
    # A replacement of the VM plans its id as unknown; an in-place update or a
    # refresh after a restore keeps it.
    replace_triggered_by = [proxmox_virtual_environment_vm.this.id]
  }
}

resource "proxmox_virtual_environment_vm" "this" {
  name          = var.name
  node_name     = var.node_name
  vm_id         = var.vm_id
  pool_id       = var.pool_id
  tags          = var.tags
  scsi_hardware = "virtio-scsi-single"
  on_boot       = var.on_boot

  # The disk first: until nixos-anywhere has put GRUB on it, SeaBIOS falls
  # through to the installer; afterwards it boots the installed system.
  boot_order = ["virtio0", "ide3"]

  # Creating the VM waits for the agent, so the installer's address is known
  # when the install starts.
  agent {
    enabled = true
    timeout = "15m"
    trim    = false
  }

  cpu {
    cores = var.cores
    type  = var.cpu_type
  }

  # With memory_floating below memory, the guest's balloon driver hands idle
  # memory back when the host runs short, down to memory_floating.
  memory {
    dedicated = var.memory
    floating  = var.memory_floating
  }

  # Empty until disko partitions it. Growing it later grows the root
  # filesystem on the next boot.
  disk {
    interface    = "virtio0"
    datastore_id = var.datastore_id
    file_format  = "raw"
    size         = var.disk_size
    discard      = "ignore"
    iothread     = true
  }

  # Data disks after it, virtio1 onwards: /dev/vdb, /dev/vdc, ... on the
  # host, mounted where nixosModules.proxmox-guest's dataDisks says.
  dynamic "disk" {
    for_each = var.data_disks
    content {
      interface    = "virtio${disk.key + 1}"
      datastore_id = var.datastore_id
      file_format  = "raw"
      size         = disk.value.size
      discard      = "ignore"
      iothread     = true
      backup       = disk.value.backup
    }
  }

  cdrom {
    enabled   = true
    file_id   = var.installer_iso_id
    interface = "ide3"
  }

  network_device {
    bridge   = var.bridge
    enabled  = true
    firewall = true
    model    = "virtio"
    vlan_id  = var.vlan_id
  }

  operating_system {
    type = "l26"
  }
}

module "system" {
  source = "github.com/nix-community/nixos-anywhere//terraform/nix-build?ref=1.13.0"

  attribute = "${var.flake}#nixosConfigurations.${var.host}.config.system.build.toplevel"
}

module "disko" {
  source = "github.com/nix-community/nixos-anywhere//terraform/nix-build?ref=1.13.0"

  attribute = "${var.flake}#nixosConfigurations.${var.host}.config.system.build.diskoScript"
}

module "install" {
  source = "github.com/nix-community/nixos-anywhere//terraform/install?ref=1.13.0"

  nixos_partitioner = module.disko.result.out
  nixos_system      = module.system.result.out
  # Only the install uses this, and a different value later changes nothing;
  # the fallback keeps plans working while the VM is off. On a new VM the
  # installer's guest agent answers only once DHCP gave it an address
  # (nixosModules.installer), and creating the VM waits for the agent, so the
  # install never falls back to the static address.
  target_host     = try(local.installer_addresses[0], var.address)
  target_user     = "root"
  ssh_private_key = var.ssh_private_key
  instance_id     = local.installation_id
  # The installer is NixOS already, so there is nothing to kexec into.
  phases = ["disko", "install", "reboot"]

  # The files reach the script through the environment, which is not kept in
  # the state, and never touch the flake or the Nix store.
  extra_files_script = length(var.extra_files) > 0 ? "${path.module}/extra-files.sh" : null
  extra_environment  = length(var.extra_files) > 0 ? { EXTRA_FILES = jsonencode(var.extra_files) } : {}
}

module "deploy" {
  source = "github.com/nix-community/nixos-anywhere//terraform/nixos-rebuild?ref=1.13.0"

  nixos_system    = module.system.result.out
  target_host     = var.address
  target_user     = "root"
  ssh_private_key = var.ssh_private_key

  depends_on = [module.install]
}
