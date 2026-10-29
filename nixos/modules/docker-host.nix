# A Docker host: a VM whose owner runs a Docker Compose stack on it by hand,
# reverse proxy included, behind the host's shared ingress. It adds Docker and
# a static address, and keeps the stack off the LAN but for the ingress ports,
# which only the ingress may reach.
#
# Docker publishes a container's ports through DNAT in prerouting, so a
# published port never reaches the INPUT chain that networking.firewall
# filters. The rules here sit in tables of their own, ahead of Docker's: they
# limit the ingress ports to their sources before Docker translates them, and
# drop any other connection from the LAN that Docker would forward to a
# container.
{
  config,
  lib,
  ...
}:
let
  cfg = config.servacho.dockerHost;
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    ;

  nftSet = xs: "{ ${lib.concatStringsSep ", " (map toString xs)} }";

  # The VM's NIC by name, not Type=ether: Docker's veths are ether too.
  nic = "en*";
  ports = nftSet cfg.ingress.ports;
  allowSources = lib.optionalString (
    cfg.ingress.sources != [ ]
  ) ''iifname "${nic}" tcp dport ${ports} ip saddr ${nftSet cfg.ingress.sources} accept'';
in
{
  options.servacho.dockerHost = {
    enable = mkEnableOption "a servacho Docker host";

    network = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            address = mkOption {
              type = types.str;
              example = "192.168.10.41";
            };
            prefixLength = mkOption {
              type = types.ints.between 0 32;
              example = 23;
            };
            gateway = mkOption {
              type = types.str;
              example = "192.168.10.1";
            };
            nameservers = mkOption {
              type = types.listOf types.str;
              default = [
                "1.1.1.1"
                "1.0.0.1"
              ];
            };
          };
        }
      );
      default = null;
      description = ''
        A static address for the host's NIC, applied through systemd-networkd.
        null leaves networking to the host configuration.
      '';
    };

    ingress = {
      ports = mkOption {
        type = types.listOf types.port;
        default = [
          80
          443
        ];
        description = ''
          The TCP ports the stack's reverse proxy listens on, published or on
          the host's network. The only ports of the stack the LAN can reach.
        '';
      };

      sources = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "192.168.4.16/32" ];
        description = ''
          Source CIDRs allowed to reach the ingress ports: the shared ingress
          that forwards the host's names to it. Empty, nothing reaches them.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    # Containers log to the journal, NixOS's default for Docker, which base
    # caps at 1 GiB; images, containers and networks no stack uses are pruned
    # weekly. Compose comes with the docker package as its plugin.
    virtualisation.docker = {
      enable = true;
      autoPrune = {
        enable = true;
        dates = "weekly";
      };
    };

    # For a reverse proxy on the host's network: Docker's published ports
    # never reach this chain (above).
    networking.firewall.extraInputRules = lib.optionalString (cfg.ingress.sources != [ ]) ''
      ip saddr ${nftSet cfg.ingress.sources} tcp dport ${ports} accept
    '';

    networking.nftables.tables.docker-host = {
      family = "inet";
      content = ''
        # Before Docker's DNAT (dstnat, -100): the ingress ports from their
        # sources only, whether a container or the host answers them.
        chain prerouting {
          type filter hook prerouting priority dstnat - 1; policy accept;
          ${allowSources}
          iifname "${nic}" tcp dport ${ports} drop
        }

        # Before Docker's filter (0): a connection from the LAN that Docker
        # translated to a container is forwarded only for an ingress port.
        # The containers' own connections out, and their replies, are not
        # translated this way and pass.
        chain forward {
          type filter hook forward priority filter - 1; policy accept;
          iifname "${nic}" ct status dnat meta l4proto tcp ct original proto-dst ${ports} accept
          iifname "${nic}" ct status dnat drop
        }
      '';
    };

    systemd.network = mkIf (cfg.network != null) {
      enable = true;
      networks."10-lan" = {
        matchConfig.Name = nic;
        address = [ "${cfg.network.address}/${toString cfg.network.prefixLength}" ];
        gateway = [ cfg.network.gateway ];
        dns = cfg.network.nameservers;
      };
    };
    networking.useDHCP = mkIf (cfg.network != null) false;
  };
}
