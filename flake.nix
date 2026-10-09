{
  description = "Reusable NixOS modules and installer for servacho's Proxmox VMs and the organisations' infrastructure";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # Partitions a VM's disk when nixos-anywhere installs a host onto it.
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (nixpkgs) lib;

      # Stand-ins for a consumer's hosts, so the checks build each kind of
      # system the modules make.
      example =
        modules:
        lib.nixosSystem {
          inherit system;
          modules = [ { system.stateVersion = "26.05"; } ] ++ modules;
        };
      exampleNetwork = {
        address = "192.0.2.15";
        prefixLength = 24;
        gateway = "192.0.2.1";
      };
    in
    {
      nixosModules = {
        # What every VM shares: SSH by key only, the QEMU guest agent, the
        # nftables firewall, Nix housekeeping.
        base = ./nixos/modules/base.nix;
        # servacho.managementPlane.*: OpenTofu, OpenBao and an optional runner.
        management-plane = ./nixos/modules/management-plane.nix;
        # servacho.k3s.*: a k3s server or agent with its firewall and Longhorn's host side.
        k3s-node = ./nixos/modules/k3s-node.nix;
        # The hardware and disk layout of a VM installed by tofu/modules/nixos-vm.
        proxmox-guest = {
          imports = [
            disko.nixosModules.disko
            ./nixos/modules/proxmox-guest.nix
          ];
        };
        # servacho.installer.*: the ISO tofu/modules/nixos-vm boots VMs from.
        installer = ./nixos/modules/installer.nix;
      };

      checks.${system} = {
        management-plane =
          (example [
            self.nixosModules.base
            self.nixosModules.management-plane
            self.nixosModules.proxmox-guest
            {
              networking.hostName = "example-management-plane";
              servacho.managementPlane = {
                enable = true;
                network = exampleNetwork;
                runner = {
                  enable = true;
                  url = "https://github.com/angel-penchev/servacho-infrastructure";
                  labels = [ "example-management-plane" ];
                  ephemeral = true;
                };
              };
            }
          ]).config.system.build.toplevel;
        k3s-server =
          (example [
            self.nixosModules.base
            self.nixosModules.k3s-node
            self.nixosModules.proxmox-guest
            {
              networking.hostName = "example-k3s-server";
              servacho.k3s = {
                enable = true;
                role = "server";
                clusterNetworks = [ "192.0.2.0/24" ];
                apiSources = [ "198.51.100.15/32" ];
                flannelBackend = "wireguard-native";
                longhorn.enable = true;
              };
              servacho.proxmoxGuest.dataDisks = [ "/var/lib/longhorn" ];
            }
          ]).config.system.build.toplevel;
        k3s-agent =
          (example [
            self.nixosModules.base
            self.nixosModules.k3s-node
            self.nixosModules.proxmox-guest
            {
              networking.hostName = "example-k3s-agent";
              servacho.k3s = {
                enable = true;
                role = "agent";
                clusterNetworks = [ "192.0.2.0/24" ];
                flannelBackend = "wireguard-native";
                imageGC = {
                  highThreshold = 75;
                  lowThreshold = 60;
                };
              };
            }
          ]).config.system.build.toplevel;
        installer =
          (lib.nixosSystem {
            inherit system;
            modules = [ self.nixosModules.installer ];
          }).config.system.build.toplevel;
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
