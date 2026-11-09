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
      # A static address and a private resolver, as servacho.egress needs.
      exampleStaticNetwork = address: {
        networking.useDHCP = false;
        systemd.network = {
          enable = true;
          networks."10-lan" = {
            matchConfig.Name = "en*";
            address = [ "${address}/24" ];
            gateway = [ "10.0.10.1" ];
            dns = [ "10.0.10.53" ];
          };
        };
      };

      examples = {
        management-plane = example [
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
            servacho.ssh.sources = "any";
          }
        ];
        k3s-server = example [
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
            servacho.ssh.sources = "any";
          }
        ];
        k3s-agent = example [
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
            servacho.ssh.sources = "any";
          }
        ];
        docker-host = example [
          self.nixosModules.base
          self.nixosModules.docker-host
          self.nixosModules.proxmox-guest
          {
            networking.hostName = "example-docker-host";
            servacho.dockerHost = {
              enable = true;
              network = exampleNetwork;
              ingress.sources = [ "198.51.100.16/32" ];
            };
            servacho.ssh.sources = "any";
          }
        ];
        # SSH from an IPv4 and IPv6 list, and every kind of egress entry.
        egress-host = example [
          self.nixosModules.base
          self.nixosModules.proxmox-guest
          (exampleStaticNetwork "10.0.10.20")
          {
            networking.hostName = "example-egress-host";
            servacho.ssh.sources = [
              "10.0.10.15"
              "192.0.2.0/24"
              "2001:db8:2::/64"
            ];
            servacho.egress = {
              enable = true;
              allow = [ "fd00:10::10" ];
              allowTcp = [
                {
                  address = "10.0.5.10";
                  ports = [ 8006 ];
                }
                {
                  address = "10.0.10.0/24";
                  ports = [
                    22
                    6443
                  ];
                }
                # Inside the /24 above, on the same port: the rules must load.
                {
                  address = "10.0.10.15";
                  ports = [ 22 ];
                }
                {
                  address = "fd00:10::/64";
                  ports = [ 443 ];
                }
              ];
              allowUdp = [
                {
                  address = "10.0.10.123";
                  ports = [ 123 ];
                }
              ];
              extraRules = "meta skuid 0 ip daddr 10.0.12.0/24 tcp dport 22 accept";
            };
          }
        ];
        k3s-agent-egress = example [
          self.nixosModules.base
          self.nixosModules.k3s-node
          self.nixosModules.proxmox-guest
          (exampleStaticNetwork "10.0.10.37")
          {
            networking.hostName = "example-k3s-agent-egress";
            servacho.k3s = {
              enable = true;
              role = "agent";
              clusterNetworks = [
                "10.0.10.36/32"
                "10.0.10.37/32"
              ];
              flannelBackend = "wireguard-native";
            };
            servacho.ssh.sources = [
              "10.0.10.15"
              "192.0.2.0/24"
            ];
            servacho.egress.enable = true;
          }
        ];
        k3s-server-egress = example [
          self.nixosModules.base
          self.nixosModules.k3s-node
          self.nixosModules.proxmox-guest
          (exampleStaticNetwork "10.0.10.36")
          {
            networking.hostName = "example-k3s-server-egress";
            servacho.k3s = {
              enable = true;
              role = "server";
              clusterNetworks = [ "10.0.10.0/24" ];
              apiSources = [ "10.0.10.15/32" ];
            };
            servacho.ssh = {
              sources = [
                "10.0.10.15"
                "192.0.2.0/24"
              ];
              logOnly = true;
            };
            servacho.egress = {
              enable = true;
              logOnly = true;
            };
          }
        ];
      };
    in
    {
      nixosModules = {
        # What every VM shares: SSH by key only from the sources each host
        # sets, an optional egress filter, the QEMU guest agent, the nftables
        # firewall, Nix housekeeping.
        base = ./nixos/modules/base.nix;
        # servacho.managementPlane.*: OpenTofu, OpenBao and an optional runner.
        management-plane = ./nixos/modules/management-plane.nix;
        # servacho.k3s.*: a k3s server or agent with its firewall and Longhorn's host side.
        k3s-node = ./nixos/modules/k3s-node.nix;
        # servacho.dockerHost.*: Docker for a Compose stack behind the shared ingress.
        docker-host = ./nixos/modules/docker-host.nix;
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

      checks.${system} = lib.mapAttrs (_: host: host.config.system.build.toplevel) examples // {
        installer =
          (lib.nixosSystem {
            inherit system;
            modules = [ self.nixosModules.installer ];
          }).config.system.build.toplevel;
        # The script each example's nftables service runs. The build checks
        # it only under LKL, so CI also loads each one into the runner's
        # kernel.
        nftables-rules = pkgs.linkFarm "nftables-rules" (
          lib.mapAttrsToList (name: host: {
            inherit name;
            path = lib.elemAt host.config.systemd.services.nftables.serviceConfig.ExecStart 1;
          }) examples
        );
        firewall-eval = import ./nixos/tests/firewall-eval.nix {
          inherit
            lib
            pkgs
            self
            system
            ;
        };
        firewall-vm = import ./nixos/tests/firewall-vm.nix { inherit pkgs self; };
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
