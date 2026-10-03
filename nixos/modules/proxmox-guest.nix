# The hardware of a Proxmox VM installed by nixos-anywhere (tofu/modules/nixos-vm):
# one virtio disk that disko partitions during the install, legacy GRUB for the
# VM's SeaBIOS, and the QEMU guest profile. A host that imports this needs no
# generated hardware-configuration.nix. The flake's nixosModules.proxmox-guest
# brings disko's NixOS module with it.
{ lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  # GPT with a BIOS boot partition for GRUB and the rest as the root
  # filesystem. The EF02 partition is what makes disko point GRUB at the disk.
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/vda";
    content = {
      type = "gpt";
      partitions = {
        bios = {
          size = "1M";
          type = "EF02";
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };

  # OpenTofu may grow the disk later; the partition and filesystem follow on
  # the next boot.
  boot.growPartition = true;
  fileSystems."/".autoResize = true;

  boot.loader.grub.enable = true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
