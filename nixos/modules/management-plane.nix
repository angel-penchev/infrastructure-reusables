# A management plane: the VM that holds one organisation's OpenTofu state, its
# OpenBao and, once the organisation has an infrastructure repository, the
# GitHub Actions runner that applies it. servacho's root plane and every
# organisation's plane are this module with a different address, OpenBao node
# and repository (servacho-infrastructure's docs/tenant-management-planes.md).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.servacho.managementPlane;
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    ;
in
{
  options.servacho.managementPlane = {
    enable = mkEnableOption "a servacho management plane";

    openbao.nodeId = mkOption {
      type = types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "Raft node id of this plane's single-node OpenBao.";
    };

    network = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            address = mkOption {
              type = types.str;
              example = "192.168.10.11";
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
        A static address for the plane's one interface, applied through
        systemd-networkd to whichever ethernet device the VM has. null leaves
        networking to the host configuration, as on the hand-installed root
        plane.
      '';
    };

    runner = {
      enable = mkEnableOption "the GitHub Actions runner that applies this plane's repository";

      name = mkOption {
        type = types.str;
        default = "management-runner";
        description = "Runner name; the systemd unit is github-runner-<name>.";
      };

      url = mkOption {
        type = types.str;
        example = "https://github.com/angel-penchev/servacho-infrastructure";
        description = "The repository the runner registers with.";
      };

      labels = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Labels the repository's workflows select the runner by.";
      };

      tokenFile = mkOption {
        type = types.str;
        default = "/var/lib/github-runner/.token";
        description = ''
          Registration token, needed once: the runner registers with it on its
          first start and keeps its own credentials from then on. Until the
          file exists the runner does not start, so a plane can be deployed
          with the runner enabled before its token arrives.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    nixpkgs.config.allowUnfree = true;

    environment.systemPackages = with pkgs; [
      opentofu
      git
      colmena
      vim
      neovim
      openbao
    ];

    environment.variables = {
      EDITOR = "nvim";
      VISUAL = "nvim";
    };

    # OpenBao is only reachable by processes on the plane itself. Workloads
    # that need an organisation's secrets get a listener on its VLAN, with TLS,
    # when its first consumer arrives; nothing opens it before.
    services.openbao = {
      enable = true;
      settings = {
        ui = true;
        api_addr = "http://127.0.0.1:8200";
        cluster_addr = "http://127.0.0.1:8201";

        listener.tcp = {
          type = "tcp";
          address = "127.0.0.1:8200";
          tls_disable = 1;
        };

        storage.raft = {
          path = "/var/lib/openbao";
          node_id = cfg.openbao.nodeId;
        };
      };
    };

    systemd.network = mkIf (cfg.network != null) {
      enable = true;
      networks."10-lan" = {
        matchConfig.Type = "ether";
        address = [ "${cfg.network.address}/${toString cfg.network.prefixLength}" ];
        gateway = [ cfg.network.gateway ];
        dns = cfg.network.nameservers;
      };
    };
    networking.useDHCP = mkIf (cfg.network != null) false;

    # Compressed swap in RAM: a burst of Nix evaluations in a plan slows down
    # instead of the OOM killer taking the runner, and with it the job.
    zramSwap = {
      enable = true;
      memoryPercent = 50;
    };

    services.github-runners = mkIf cfg.runner.enable {
      ${cfg.runner.name} = {
        enable = true;
        inherit (cfg.runner) url tokenFile;
        extraPackages = with pkgs; [
          opentofu
          git
          colmena
          # The plane deploys NixOS, its own and its VMs', from inside a job
          # (nixos-anywhere's OpenTofu modules): nix-build.sh needs jq, nix copy
          # and the switch need ssh.
          jq
          openssh
          curl
        ];
        extraLabels = cfg.runner.labels;

        # The runner service uses ProtectSystem=strict. StateDirectory makes
        # this persistent directory writable to its dynamically allocated user.
        serviceOverrides = {
          StateDirectory = [
            "github-runner/${cfg.runner.name}"
            "opentofu"
          ];
          StateDirectoryMode = "0700";
        };
      };
    };

    # The runner deploys this very configuration from inside a job. Restarting
    # its unit mid-switch would kill that job and leave OpenTofu's state locked,
    # so a new runner version waits for the next reboot or a manual restart.
    systemd.services."github-runner-${cfg.runner.name}" = mkIf cfg.runner.enable {
      restartIfChanged = false;
      # Skipped, not failed, until it has a token to register with or has
      # registered already: a switch that enables the runner before the token
      # is placed would otherwise fail on the unit.
      unitConfig.ConditionPathExists = [
        "|${cfg.runner.tokenFile}"
        "|/var/lib/github-runner/${cfg.runner.name}/.runner"
      ];
    };

    # Keep parent directory traversable for the runner service process.
    systemd.tmpfiles.rules = mkIf cfg.runner.enable [
      "d /var/lib/github-runner 0755 root root -"
    ];
  };
}
