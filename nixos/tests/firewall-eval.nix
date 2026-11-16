# Evaluation checks for nixos/modules/firewall.nix, with nothing to build:
# each assertion fires where it must and nowhere else, options merge as the
# README says, and the generated rules have the expected text. A failed case
# fails the evaluation of checks.firewall-eval and names the case.
{
  lib,
  pkgs,
  self,
  system,
}:
let
  host =
    modules:
    (lib.nixosSystem {
      inherit system;
      modules = [
        {
          system.stateVersion = "26.05";
          networking.hostName = "firewall-eval";
        }
        self.nixosModules.base
      ]
      ++ modules;
    }).config;

  # The firewall assertions that fail, by a short name. Only failed
  # assertions are read, because other modules' messages may need a
  # configuration this host does not have.
  assertionNames = {
    "servacho.ssh.sources is not set" = "unset";
    "servacho.ssh.sources is an empty list" = "empty";
    "servacho.ssh.sources is a list, but networking.firewall also opens" = "reopened";
    "servacho.ssh.sources is a list, but the NixOS firewall" = "firewall";
    "servacho.ssh.logOnly and servacho.egress add tables" = "nftables";
    "servacho.egress needs a static address" = "dhcp";
  };
  failed =
    config:
    lib.concatMap (
      a:
      lib.mapAttrsToList (_: name: name) (
        lib.filterAttrs (prefix: _: lib.hasPrefix prefix a.message) assertionNames
      )
    ) (builtins.filter (a: !a.assertion) config.assertions);

  fails = config: !(builtins.tryEval (builtins.deepSeq config.servacho null)).success;
  addressOk =
    (lib.nixosSystem {
      inherit system;
      modules = [ self.nixosModules.base ];
    }).options.servacho.egress.allow.type.nestedTypes.elemType.check;
  table = config: name: config.networking.nftables.tables.${name}.content;
  servachoTables =
    config:
    builtins.filter (lib.hasPrefix "servacho-") (lib.attrNames config.networking.nftables.tables);
  # The texts out of the list that the content does not hold.
  missing = content: builtins.filter (text: !lib.hasInfix text content);
  present = content: builtins.filter (text: lib.hasInfix text content);
  line = content: prefix: lib.findFirst (lib.hasPrefix prefix) null (lib.splitString "\n" content);
  count = text: content: lib.length (lib.splitString text content) - 1;
  inputRules =
    config:
    builtins.filter (l: l != "") (lib.splitString "\n" config.networking.firewall.extraInputRules);
  sshLog =
    ports:
    ''tcp dport { ${ports} } counter limit rate 6/minute log prefix "servacho-ssh-refused: " level info'';

  sources = [
    "10.0.10.15"
    "192.0.2.0/24"
    "2001:db8:2::/64"
  ];
  any.servacho.ssh.sources = "any";
  list.servacho.ssh.sources = sources;
  logOnly = {
    servacho.ssh = {
      inherit sources;
      logOnly = true;
    };
  };
  noNftables.networking.nftables.enable = lib.mkForce false;
  firewallOff.networking.firewall.enable = lib.mkForce false;
  static = {
    networking.useDHCP = false;
    systemd.network = {
      enable = true;
      networks."10-lan" = {
        matchConfig.Name = "en*";
        address = [ "10.0.10.20/24" ];
        gateway = [ "10.0.10.1" ];
        dns = [ "10.0.10.53" ];
      };
    };
  };
  egress.servacho.egress.enable = true;
  egressHost = [
    any
    static
    egress
  ];
  k3s = role: flannelBackend: [
    self.nixosModules.k3s-node
    {
      servacho.k3s = {
        enable = true;
        inherit role flannelBackend;
        clusterNetworks = [
          "10.0.10.36/32"
          "10.0.10.37/32"
        ];
      };
    }
  ];
  docker = [
    self.nixosModules.docker-host
    {
      servacho.dockerHost = {
        enable = true;
        network = {
          address = "10.0.10.41";
          prefixLength = 24;
          gateway = "10.0.10.1";
        };
      };
    }
  ];
  dockerWarning = "servacho.egress filters only what the host itself sends";

  anyHost = host [ any ];
  listHost = host [ list ];
  logOnlyHost = host [ logOnly ];
  egressTable = table (host (
    egressHost
    ++ [
      {
        servacho.egress = {
          allow = [ "fd00:10::10" ];
          allowTcp = [
            {
              address = "10.0.5.10";
              ports = [ 8006 ];
            }
            {
              address = "fd00:10::/64";
              ports = [ 443 ];
            }
            {
              address = "10.0.10.53";
              ports = [ 53 ];
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
    ]
  )) "servacho-egress";
  egressLogOnlyTable = table (host (
    egressHost ++ [ { servacho.egress.logOnly = true; } ]
  )) "servacho-egress";
  k3sAgent = host (egressHost ++ k3s "agent" "wireguard-native");
  k3sServer = host (egressHost ++ k3s "server" "vxlan");
  dockerEgress = host (egressHost ++ docker);

  tests = {
    testAssertUnset = {
      expr = failed (host [ ]);
      expected = [ "unset" ];
    };
    testAssertAny = {
      expr = failed anyHost;
      expected = [ ];
    };
    testAssertList = {
      expr = failed listHost;
      expected = [ ];
    };
    testAssertEmpty = {
      expr = failed (host [ { servacho.ssh.sources = [ ]; } ]);
      expected = [ "empty" ];
    };
    testAssertPort = {
      expr = failed (host [
        list
        { networking.firewall.allowedTCPPorts = [ 22 ]; }
      ]);
      expected = [ "reopened" ];
    };
    testAssertRange = {
      expr = failed (host [
        list
        {
          networking.firewall.allowedTCPPortRanges = [
            {
              from = 20;
              to = 30;
            }
          ];
        }
      ]);
      expected = [ "reopened" ];
    };
    testAssertInterfacePort = {
      expr = failed (host [
        list
        { networking.firewall.interfaces.ens18.allowedTCPPorts = [ 22 ]; }
      ]);
      expected = [ "reopened" ];
    };
    testAssertInterfaceRange = {
      expr = failed (host [
        list
        {
          networking.firewall.interfaces.ens18.allowedTCPPortRanges = [
            {
              from = 22;
              to = 22;
            }
          ];
        }
      ]);
      expected = [ "reopened" ];
    };
    testAssertOtherSshPort = {
      expr = failed (host [
        list
        {
          services.openssh.ports = [ 2222 ];
          networking.firewall.allowedTCPPorts = [ 2222 ];
        }
      ]);
      expected = [ "reopened" ];
    };
    testAssertPortNotSsh = {
      expr = failed (host [
        list
        {
          services.openssh.ports = [ 2222 ];
          networking.firewall.allowedTCPPorts = [ 22 ];
        }
      ]);
      expected = [ ];
    };
    testAssertLogOnlyPort = {
      expr = failed (host [
        logOnly
        { networking.firewall.allowedTCPPorts = [ 22 ]; }
      ]);
      expected = [ ];
    };
    testAssertListNoNftables = {
      expr = failed (host [
        list
        noNftables
      ]);
      expected = [ "firewall" ];
    };
    testAssertListFirewalld = {
      expr = failed (host [
        list
        { services.firewalld.enable = true; }
      ]);
      expected = [ "firewall" ];
    };
    testAssertListIptables = {
      expr = failed (host [
        list
        { networking.firewall.backend = "iptables"; }
      ]);
      expected = [ "firewall" ];
    };
    testAssertListFirewallOff = {
      expr = failed (host [
        list
        firewallOff
      ]);
      expected = [ "firewall" ];
    };
    testAssertLogOnlyFirewallOff = {
      expr = failed (host [
        logOnly
        firewallOff
      ]);
      expected = [ ];
    };
    testAssertAnyFirewalld = {
      expr = failed (host [
        any
        { services.firewalld.enable = true; }
      ]);
      expected = [ ];
    };
    testAssertLogOnlyNoNftables = {
      expr = failed (host [
        logOnly
        noNftables
      ]);
      expected = [ "nftables" ];
    };
    testAssertAnyNoNftables = {
      expr = failed (host [
        any
        noNftables
      ]);
      expected = [ ];
    };
    testAssertEgressNoNftables = {
      expr = failed (host (egressHost ++ [ noNftables ]));
      expected = [ "nftables" ];
    };
    testAssertEgressDhcp = {
      expr = failed (host [
        any
        egress
      ]);
      expected = [ "dhcp" ];
    };
    testAssertEgressInterfaceDhcp = {
      expr = failed (host (egressHost ++ [ { networking.interfaces.ens18.useDHCP = true; } ]));
      expected = [ "dhcp" ];
    };
    testAssertEgressNetworkdDhcp = {
      expr = failed (host (egressHost ++ [ { systemd.network.networks."20-wan".DHCP = "ipv4"; } ]));
      expected = [ "dhcp" ];
    };
    testAssertEgressNetworkConfigDhcp = {
      expr = failed (
        host (egressHost ++ [ { systemd.network.networks."20-wan".networkConfig.DHCP = "yes"; } ])
      );
      expected = [ "dhcp" ];
    };
    testAssertEgressStatic = {
      expr = failed (host egressHost);
      expected = [ ];
    };

    # nixpkgs prints an evaluation warning for this case. It deprecates a
    # merge of both kinds of value in an either type. The warning is
    # expected, and the conflict still fails the evaluation.
    testAnyAndListConflict = {
      expr = fails (host [
        any
        list
      ]);
      expected = true;
    };
    testDefaultAnyGivesWayToList = {
      expr =
        (host [
          { servacho.ssh.sources = lib.mkDefault "any"; }
          list
        ]).servacho.ssh.sources;
      expected = sources;
    };
    testListsJoin = {
      expr =
        lib.sort lib.lessThan
          (host [
            list
            { servacho.ssh.sources = [ "198.51.100.7" ]; }
          ]).servacho.ssh.sources;
      expected = lib.sort lib.lessThan (sources ++ [ "198.51.100.7" ]);
    };
    testBadSource = {
      expr = fails (host [ { servacho.ssh.sources = [ "192.0.2.0/24," ]; } ]);
      expected = true;
    };
    testAddressesAccepted = {
      expr = builtins.filter (a: !addressOk a) [
        "0.0.0.0/0"
        "10.0.0.0/8"
        "10.0.10.36/32"
        "192.168.10.0/23"
        "255.255.255.255"
        "::/0"
        "fd00::/7"
        "fe80::1/128"
        "2001:db8::1"
        "::ffff:192.0.2.1"
      ];
      expected = [ ];
    };
    testAddressesRefused = {
      expr = builtins.filter addressOk [
        ""
        "192.168.5"
        "10.0.0.256"
        "192.168.005.015"
        "010.0.0.1"
        "1.2.3.4/33"
        "1.2.3.4/"
        "dead"
        "fd00::/129"
        "192.0.2.0/24,"
      ];
      expected = [ ];
    };
    testBadInterface = {
      expr = fails (host [
        any
        { servacho.egress.allowInterfaces = [ ''cni0" accept'' ]; }
      ]);
      expected = true;
    };

    testAnyChangesNothing = {
      expr = {
        open = anyHost.services.openssh.openFirewall;
        rules = anyHost.networking.firewall.extraInputRules;
        tables = servachoTables anyHost;
      };
      expected = {
        open = true;
        rules = "";
        tables = [ ];
      };
    };
    testListRules = {
      expr = {
        open = listHost.services.openssh.openFirewall;
        rules = inputRules listHost;
        tables = servachoTables listHost;
      };
      expected = {
        open = false;
        rules = [
          "ip saddr { 10.0.10.15, 192.0.2.0/24 } tcp dport { 22 } accept"
          "ip6 saddr { 2001:db8:2::/64 } tcp dport { 22 } accept"
          (sshLog "22")
        ];
        tables = [ ];
      };
    };
    testListIPv4Only = {
      expr = inputRules (host [ { servacho.ssh.sources = [ "10.0.10.15" ]; } ]);
      expected = [
        "ip saddr { 10.0.10.15 } tcp dport { 22 } accept"
        (sshLog "22")
      ];
    };
    testListSshPorts = {
      expr = inputRules (host [
        list
        {
          services.openssh.ports = [
            22
            2222
          ];
        }
      ]);
      expected = [
        "ip saddr { 10.0.10.15, 192.0.2.0/24 } tcp dport { 22, 2222 } accept"
        "ip6 saddr { 2001:db8:2::/64 } tcp dport { 22, 2222 } accept"
        (sshLog "22, 2222")
      ];
    };
    testLogOnly = {
      expr = {
        open = logOnlyHost.services.openssh.openFirewall;
        rules = logOnlyHost.networking.firewall.extraInputRules;
        tables = servachoTables logOnlyHost;
        missing = missing (table logOnlyHost "servacho-ssh-audit") [
          "type filter hook input priority filter - 1; policy accept;"
          ''iifname != "lo" tcp dport { 22 } ct state new jump check''
          "ip saddr { 10.0.10.15, 192.0.2.0/24 } return"
          "ip6 saddr { 2001:db8:2::/64 } return"
          "meta nfproto ipv4 update @outside4 { ip saddr }"
        ];
      };
      expected = {
        open = true;
        rules = "";
        tables = [ "servacho-ssh-audit" ];
        missing = [ ];
      };
    };

    testEgressOff = {
      expr = {
        tables = servachoTables (host [
          list
          static
        ]);
        llmnr = (host [ any ]).services.resolved.settings.Resolve ? LLMNR;
      };
      expected = {
        tables = [ ];
        llmnr = false;
      };
    };
    testEgressLlmnr = {
      expr = {
        default = (host egressHost).services.resolved.settings.Resolve.LLMNR;
        set =
          (host (egressHost ++ [ { services.resolved.settings.Resolve.LLMNR = "resolve"; } ]))
          .services.resolved.settings.Resolve.LLMNR;
      };
      expected = {
        default = "no";
        set = "resolve";
      };
    };
    testEgressTable = {
      expr = missing egressTable [
        "set blocked4 { type ipv4_addr; flags interval; auto-merge; elements = { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255 }; }"
        "set blocked6 { type ipv6_addr; flags interval; auto-merge; elements = { fc00::/7, fe80::/10, ff00::/8 }; }"
        "set allow6 { type ipv6_addr; flags interval; auto-merge; elements = { fd00:10::10 }; }"
        ''oifname { "lo" } accept''
        "ip daddr 10.0.5.10 tcp dport { 8006 } accept"
        "ip6 daddr fd00:10::/64 tcp dport { 443 } accept"
        "ip daddr 10.0.10.123 udp dport { 123 } accept"
        "ip daddr 10.0.10.53 tcp dport { 53 } accept"
        "ip daddr 10.0.10.53 udp dport { 53 } accept"
        "meta skuid 0 ip daddr 10.0.12.0/24 tcp dport 22 accept"
        "ct status dnat accept"
        "ip protocol igmp drop"
        "ip6 daddr ff02::/16 drop"
        "ip daddr @blocked4 counter reject with icmpx admin-prohibited"
        "ip6 daddr @blocked6 counter reject with icmpx admin-prohibited"
        "ct state new ct status dnat fib saddr type local jump dnat-out"
        "ip daddr @blocked4 counter drop"
        "ip6 daddr @blocked6 counter drop"
        "update @refused4 { ip daddr . meta l4proto . th dport }"
      ];
      expected = [ ];
    };
    testEgressPairOnce = {
      expr = count "ip daddr 10.0.10.53 tcp dport { 53 } accept" egressTable;
      expected = 1;
    };
    testEgressLogOnly = {
      expr = {
        refusals = present egressLogOnlyTable [
          "reject with"
          "counter drop"
          "igmp drop"
        ];
        missing = missing egressLogOnlyTable [
          "ip protocol igmp accept"
          "update @refused4"
          ''log prefix "servacho-egress: "''
        ];
      };
      expected = {
        refusals = [ ];
        missing = [ ];
      };
    };
    testEgressIPv4OnlyBlocked = {
      expr =
        let
          content = table (host (
            egressHost ++ [ { servacho.egress.blocked = [ "10.0.0.0/8" ]; } ]
          )) "servacho-egress";
        in
        {
          blocked4 = lib.hasInfix "elements = { 10.0.0.0/8 }" (line content "set blocked4");
          blocked6 = lib.hasInfix "elements" (line content "set blocked6");
        };
      expected = {
        blocked4 = true;
        blocked6 = false;
      };
    };
    testEgressResolvers = {
      expr =
        missing
          (table (host (
            egressHost
            ++ [
              {
                networking.nameservers = [ "10.0.0.55" ];
                systemd.network.networks."10-lan".dns = [
                  "10.0.0.54:5300#dns.example"
                  "[fd00::53]:5353%eth0#dns.example"
                  "fd00::54%eth0"
                ];
              }
            ]
          )) "servacho-egress")
          [
            "ip daddr 10.0.0.55 udp dport { 53 } accept"
            "ip daddr 10.0.10.53 udp dport { 53 } accept"
            "ip daddr 10.0.0.54 tcp dport { 5300 } accept"
            "ip daddr 10.0.0.54 udp dport { 5300 } accept"
            "ip6 daddr fd00::53 udp dport { 5353 } accept"
            "ip6 daddr fd00::54 tcp dport { 53 } accept"
          ];
      expected = [ ];
    };
    testEgressResolverSettings = {
      expr =
        missing
          (table (host (
            egressHost
            ++ [
              {
                systemd.network.networks = {
                  "10-lan".networkConfig.DNS = [ "10.0.0.56" ];
                  "20-other" = {
                    matchConfig.Name = "eth9";
                    networkConfig.DNS = "10.0.0.57 10.0.0.58";
                  };
                };
                services.resolved.settings.Resolve = {
                  DNS = "10.0.0.59 [fd00::59]:5353";
                  FallbackDNS = [ "10.0.0.60" ];
                };
              }
            ]
          )) "servacho-egress")
          [
            "ip daddr 10.0.0.56 udp dport { 53 } accept"
            "ip daddr 10.0.0.57 tcp dport { 53 } accept"
            "ip daddr 10.0.0.58 udp dport { 53 } accept"
            "ip daddr 10.0.0.59 udp dport { 53 } accept"
            "ip6 daddr fd00::59 tcp dport { 5353 } accept"
            "ip daddr 10.0.0.60 udp dport { 53 } accept"
          ];
      expected = [ ];
    };
    testEgressResolvedOff = {
      expr = lib.hasInfix "10.0.0.61" (
        table (host (
          egressHost
          ++ [
            {
              services.resolved = {
                enable = false;
                settings.Resolve.DNS = "10.0.0.61";
              };
            }
          ]
        )) "servacho-egress"
      );
      expected = false;
    };

    testK3sAgent = {
      expr = {
        untrusted = lib.subtractLists k3sAgent.networking.firewall.trustedInterfaces [
          "cni0"
          "flannel.1"
          "flannel-wg"
        ];
        missing = missing (table k3sAgent "servacho-egress") [
          ''oifname { "lo", "cni0", "flannel.1", "flannel-wg" } accept''
          "ip daddr 10.0.10.36/32 tcp dport { 6443, 10250 } accept"
          "ip daddr 10.0.10.37/32 tcp dport { 6443, 10250 } accept"
          "ip daddr 10.0.10.36/32 udp dport { 51820 } accept"
        ];
      };
      expected = {
        untrusted = [ ];
        missing = [ ];
      };
    };
    testK3sServer = {
      expr = missing (table k3sServer "servacho-egress") [
        "ip daddr 10.0.10.36/32 tcp dport { 6443, 10250, 2379, 2380 } accept"
        "ip daddr 10.0.10.36/32 udp dport { 8472 } accept"
      ];
      expected = [ ];
    };
    testK3sListLogLast = {
      expr = lib.last (inputRules (host ([ list ] ++ k3s "agent" "vxlan")));
      expected = sshLog "22";
    };
    testK3sEgressOff = {
      expr = servachoTables (host ([ any ] ++ k3s "agent" "vxlan"));
      expected = [ ];
    };
    testDockerEgress = {
      expr = {
        warned = lib.any (lib.hasPrefix dockerWarning) dockerEgress.warnings;
        missing = missing (table dockerEgress "servacho-egress") [
          ''oifname { "lo", "docker0", "br-*" } accept''
        ];
      };
      expected = {
        warned = true;
        missing = [ ];
      };
    };
    testDockerNoEgress = {
      expr = lib.any (lib.hasPrefix dockerWarning) (host ([ any ] ++ docker)).warnings;
      expected = false;
    };
    testInstallerWithoutFirewallOptions = {
      expr =
        lib.hasAttrByPath [ "servacho" "ssh" ]
          (lib.nixosSystem {
            inherit system;
            modules = [ self.nixosModules.installer ];
          }).options;
      expected = false;
    };
  };

  failures = lib.runTests tests;
in
if failures == [ ] then
  pkgs.writeText "firewall-eval" "${toString (lib.length (lib.attrNames tests))} cases passed\n"
else
  throw "checks.firewall-eval: ${toString (lib.length failures)} cases failed:\n${
    lib.generators.toPretty { } failures
  }"
