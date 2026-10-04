# A NixOS installer ISO for Proxmox VMs that OpenTofu installs with
# nixos-anywhere (tofu/modules/nixos-vm): the minimal installation ISO, plus
# the QEMU guest agent so Proxmox reports the address it got by DHCP (and
# nothing before it has one), and SSH for root by key only. The configuration that builds it adds the keys of the
# plane that installs from it:
#
#   users.users.root.openssh.authorizedKeys.keyFiles = [ ./deploy-key.pub ];
#
# and builds config.system.build.isoImage, which holds iso/<name>.iso.
{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}:
{
  imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ];

  options.servacho.installer.name = lib.mkOption {
    type = lib.types.str;
    default = "servacho-installer";
    description = ''
      File name of the ISO, without the extension. It is also the name the
      ISO gets on Proxmox storage, so each organisation that uploads its own
      installer to a shared storage needs its own.
    '';
  };

  config = {
    image.baseName = lib.mkForce config.servacho.installer.name;

    services.qemuGuest.enable = true;

    # nixos-vm installs to the first address the agent reports, and creating
    # the VM waits for the agent. Until DHCP has given the installer an IPv4
    # address there is nothing to install to, so the agent stays silent until
    # then rather than reporting none.
    systemd.services.qemu-guest-agent.serviceConfig = {
      ExecStartPre = pkgs.writeShellScript "wait-for-ipv4" ''
        until ${pkgs.iproute2}/bin/ip -4 -o address show scope global | ${pkgs.gnugrep}/bin/grep -q inet; do
          sleep 1
        done
      '';
      TimeoutStartSec = "infinity";
    };

    # The installer profile ships sshd without starting it, and its root has
    # an empty password for the console; over SSH only a key gets in.
    systemd.services.sshd.wantedBy = lib.mkForce [ "multi-user.target" ];
    services.openssh.settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };
}
