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
# The install runs once per VM: a VM replaced under the same id gets a new MAC
# address and so a new installation_id, and installs again.

locals {
  # Where the installer can be reached: an address it got by DHCP, as the
  # guest agent reports it. Loopback and IPv4 link-local are not.
  installer_addresses = [
    for ip in flatten(proxmox_virtual_environment_vm.this.ipv4_addresses) : ip
    if !startswith(ip, "127.") && !startswith(ip, "169.254.")
  ]

  installation_id = join("/", [
    proxmox_virtual_environment_vm.this.vm_id,
    proxmox_virtual_environment_vm.this.network_device[0].mac_address,
  ])
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

  memory {
    dedicated = var.memory
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
  # Only the first install uses this, and a different value later changes
  # nothing; the fallback keeps plans working while the VM is off.
  target_host     = try(local.installer_addresses[0], var.address)
  target_user     = "root"
  ssh_private_key = var.ssh_private_key
  instance_id     = local.installation_id
  # The installer is NixOS already, so there is nothing to kexec into.
  phases = ["disko", "install", "reboot"]
}

module "deploy" {
  source = "github.com/nix-community/nixos-anywhere//terraform/nixos-rebuild?ref=1.13.0"

  nixos_system    = module.system.result.out
  target_host     = var.address
  target_user     = "root"
  ssh_private_key = var.ssh_private_key

  depends_on = [module.install]
}
