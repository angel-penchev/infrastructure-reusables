# The hardware of a Proxmox VM installed by nixos-anywhere (tofu/modules/nixos-vm):
# one virtio disk that disko partitions during the install, any data disks
# beside it, legacy GRUB for the VM's SeaBIOS, and the QEMU guest profile. A
# host that imports this needs no generated hardware-configuration.nix. The
# flake's nixosModules.proxmox-guest brings disko's NixOS module with it.
{
  config,
  lib,
  modulesPath,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.servacho.proxmoxGuest;
in
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  options.servacho.proxmoxGuest.dataDisks = mkOption {
    type = types.listOf types.str;
    default = [ ];
    example = [ "/var/lib/longhorn" ];
    description = ''
      Mount points of the VM's data disks, in the order of nixos-vm's
      `data_disks`: the first is the second virtio disk (/dev/vdb), and so on.
      Each disk is one ext4 filesystem with no partition table, formatted by
      disko at install and grown with its disk on the next boot.
    '';
  };

  config = {
    disko.devices.disk = {
      # GPT with a BIOS boot partition for GRUB and the rest as the root
      # filesystem. The EF02 partition is what makes disko point GRUB at the disk.
      main = {
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
    }
    # vdb, vdc, ...: virtio disks are lettered in the order of their slots.
    // lib.listToAttrs (
      lib.imap1 (
        i: mountpoint:
        lib.nameValuePair "data${toString i}" {
          type = "disk";
          device = "/dev/vd${lib.elemAt lib.lowerChars i}";
          content = {
            type = "filesystem";
            format = "ext4";
            inherit mountpoint;
          };
        }
      ) cfg.dataDisks
    );

    # OpenTofu may grow the disks later; the root partition and every
    # filesystem follow on the next boot.
    boot.growPartition = true;
    fileSystems = {
      "/".autoResize = true;
    }
    // lib.genAttrs cfg.dataDisks (_: {
      autoResize = true;
    });

    boot.loader.grub.enable = true;

    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  };
}
