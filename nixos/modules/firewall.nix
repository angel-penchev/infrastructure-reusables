# Who may open SSH connections to the host, and which private addresses the
# host may open connections to. base, k3s-node and docker-host import it, and
# every host sets servacho.ssh.sources (README, "SSH sources and egress").
{ config, lib, ... }:
let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    ;
  ssh = config.servacho.ssh;
  egress = config.servacho.egress;
  fw = config.networking.firewall;

  # An IPv4 address must have four decimal octets with no leading zero. nft
  # reads 010 as octal, and loads a different address with no error. An IPv6
  # address is only checked for its characters. The build's nft --check
  # refuses most other typos, before a host gets the rules.
  octet = "(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])";
  v4Address = "${octet}(\\.${octet}){3}(/(3[0-2]|[12]?[0-9]))?";
  v6Address = "[0-9A-Fa-f.:]*:[0-9A-Fa-f.:]*(/(12[0-8]|1[01][0-9]|[1-9]?[0-9]))?";
  addressType = types.strMatching "(${v4Address}|${v6Address})";
  interfaceType = types.strMatching "[^\"[:space:]]+";

  isV6 = lib.hasInfix ":";
  v4 = builtins.filter (x: !isV6 x);
  v6 = builtins.filter isV6;
  nftSet = xs: "{ ${lib.concatStringsSep ", " (map toString xs)} }";
  # "{ }" is not valid nft, so a rule or an element list is written only when
  # it has something in it.
  rule = xs: text: lib.optionalString (xs != [ ]) "${text}\n";
  elements = xs: lib.optionalString (xs != [ ]) "elements = ${nftSet xs};";
  ipFamily = a: if isV6 a then "ip6" else "ip";

  sshList = ssh.sources != null && ssh.sources != "any";
  sshEnforced = sshList && !ssh.logOnly;
  sshPorts = config.services.openssh.ports;
  portIn =
    p: ports: ranges:
    lib.elem p ports || lib.any (r: r.from <= p && p <= r.to) ranges;
  # An sshd port that networking.firewall opens to every source.
  sshReopened = lib.any (
    p:
    portIn p fw.allowedTCPPorts fw.allowedTCPPortRanges
    || lib.any (i: portIn p i.allowedTCPPorts i.allowedTCPPortRanges) (lib.attrValues fw.interfaces)
  ) sshPorts;

  dhcpValueOn =
    v:
    !(lib.elem v [
      null
      false
      "no"
      "none"
    ]);
  dhcpOn =
    config.networking.useDHCP
    || lib.any (i: i.useDHCP == true) (lib.attrValues config.networking.interfaces)
    || lib.any (n: dhcpValueOn n.DHCP || dhcpValueOn (n.networkConfig.DHCP or null)) (
      lib.attrValues config.systemd.network.networks
    );

  # The host's own resolvers may be private, and it needs them. systemd writes
  # them as ADDRESS[:PORT][%IFNAME][#NAME], and as [ADDRESS]:PORT for IPv6.
  # Each setting takes one string or a list, and a string can hold more than
  # one entry, separated by spaces.
  entries =
    v:
    lib.concatMap (x: builtins.filter (w: w != "") (lib.splitString " " (toString x))) (lib.toList v);
  resolver =
    s:
    let
      bare = lib.head (lib.splitString "%" (lib.head (lib.splitString "#" s)));
      bracketed = builtins.match "\\[([^]]+)](:([0-9]+))?" bare;
      v4WithPort = builtins.match "([0-9.]+):([0-9]+)" bare;
      entry = a: p: {
        address = a;
        ports = [ (if p == null then 53 else lib.toInt p) ];
      };
    in
    if bracketed != null then
      entry (lib.elemAt bracketed 0) (lib.elemAt bracketed 2)
    else if v4WithPort != null then
      entry (lib.elemAt v4WithPort 0) (lib.elemAt v4WithPort 1)
    else
      entry bare null;
  resolved = config.services.resolved;
  resolvers = map resolver (
    lib.unique (
      entries config.networking.nameservers
      ++ lib.concatMap (n: entries n.dns ++ entries (n.networkConfig.DNS or null)) (
        lib.attrValues config.systemd.network.networks
      )
      ++ lib.optionals resolved.enable (
        entries (resolved.settings.Resolve.DNS or null)
        ++ entries (resolved.settings.Resolve.FallbackDNS or null)
      )
    )
  );

  # One rule for each entry, not a set of address . port pairs: the kernel
  # refuses a concatenated interval set with overlapping entries, such as a
  # /23 and one address in it on the same port.
  pairRules =
    protocol: entries:
    lib.concatMapStrings (
      e: "${ipFamily e.address} daddr ${e.address} ${protocol} dport ${nftSet e.ports} accept\n"
    ) (lib.unique entries);

  quiet = if egress.logOnly then "accept" else "drop";
  refuse =
    verdict:
    lib.optionalString (!egress.logOnly) ''
      ip daddr @blocked4 counter ${verdict}
      ip6 daddr @blocked6 counter ${verdict}
    '';

  egressTable = ''
    set blocked4 { type ipv4_addr; flags interval; auto-merge; ${elements (v4 egress.blocked)} }
    set blocked6 { type ipv6_addr; flags interval; auto-merge; ${elements (v6 egress.blocked)} }
    set allow4 { type ipv4_addr; flags interval; auto-merge; ${elements (v4 egress.allow)} }
    set allow6 { type ipv6_addr; flags interval; auto-merge; ${elements (v6 egress.allow)} }
    # Each refused destination, or with logOnly each one that would be, for
    # 14 days. The log line has a rate limit, but these sets do not. Each
    # load of the rules deletes this table and adds it again. So a reload of
    # nftables.service or a reboot empties the sets.
    set refused4 { type ipv4_addr . inet_proto . inet_service; flags dynamic, timeout; timeout 14d; size 4096; }
    set refused6 { type ipv6_addr . inet_proto . inet_service; flags dynamic, timeout; timeout 14d; size 4096; }

    # Accepts only, because postrouting jumps here too and cannot reject.
    chain allowed {
      oifname ${nftSet (map (i: ''"${i}"'') (lib.unique ([ "lo" ] ++ egress.allowInterfaces)))} accept
      ip daddr @allow4 accept
      ip6 daddr @allow6 accept
      ${pairRules "tcp" (egress.allowTcp ++ resolvers)}
      ${pairRules "udp" (egress.allowUdp ++ resolvers)}
      ${egress.extraRules}
    }

    chain record {
      ip daddr @blocked4 ct state new meta l4proto { tcp, udp } update @refused4 { ip daddr . meta l4proto . th dport }
      ip6 daddr @blocked6 ct state new meta l4proto { tcp, udp } update @refused6 { ip6 daddr . meta l4proto . th dport }
      ip daddr @blocked4 ct state new counter limit rate 6/minute log prefix "servacho-egress: " level info
      ip6 daddr @blocked6 ct state new counter limit rate 6/minute log prefix "servacho-egress: " level info
    }

    chain output {
      type filter hook output priority filter; policy accept;
      ct state established,related accept
      # nat output (kube-proxy, Docker) changed the address already, but
      # oifname is still the device routed to before that. Postrouting
      # judges these connections.
      ct status dnat accept
      # Neighbour discovery and the MLD reports that keep a snooping switch
      # forwarding its multicast.
      icmpv6 type { nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert, mld-listener-report, mld-listener-done, mld2-listener-report } accept
      jump allowed
      # Group joins and link-local multicast (LLMNR, mDNS) are refused with
      # no record, so they do not fill the log of every host.
      ip protocol igmp ${quiet}
      ip daddr 224.0.0.0/24 ${quiet}
      ip6 daddr ff02::/16 ${quiet}
      jump record
      # A TCP connect fails at once, or at the first retransmit of its SYN
      # after about one second. To a link-local IPv6 address, the kernel does
      # not give that error to the socket. So connect waits until its timeout.
      ${refuse "reject with icmpx admin-prohibited"}
    }

    # Only the host's own connections that nat output sent elsewhere.
    # Forwarded traffic (pods, containers) has no local source address and is
    # not judged.
    chain postrouting {
      type filter hook postrouting priority filter; policy accept;
      ct state new ct status dnat fib saddr type local jump dnat-out
    }

    chain dnat-out {
      jump allowed
      jump record
      ${refuse "drop"}
    }
  '';

  # A separate table before nixos-fw: in nixos-fw's input-allow chain,
  # extraInputRules come after the open ports, so a rule there never sees a
  # connection to an open sshd port.
  sshAuditTable = ''
    set outside4 { type ipv4_addr; flags dynamic, timeout; timeout 14d; size 1024; }
    set outside6 { type ipv6_addr; flags dynamic, timeout; timeout 14d; size 1024; }

    chain input {
      type filter hook input priority filter - 1; policy accept;
      iifname != "lo" tcp dport ${nftSet sshPorts} ct state new jump check
    }

    chain check {
      ${rule (v4 ssh.sources) "ip saddr ${nftSet (v4 ssh.sources)} return"}
      ${rule (v6 ssh.sources) "ip6 saddr ${nftSet (v6 ssh.sources)} return"}
      meta nfproto ipv4 update @outside4 { ip saddr }
      meta nfproto ipv6 update @outside6 { ip6 saddr }
      counter limit rate 6/minute log prefix "servacho-ssh-outside: " level info
    }
  '';

  portEntry = types.submodule {
    options = {
      address = mkOption {
        type = addressType;
        description = "An IPv4 or IPv6 address or CIDR.";
      };
      ports = mkOption {
        type = types.nonEmptyListOf types.port;
        description = "The destination ports on that address.";
      };
    };
  };
in
{
  options.servacho.ssh = {
    sources = mkOption {
      type = types.nullOr (types.either (types.enum [ "any" ]) (types.listOf addressType));
      default = null;
      example = [
        "192.0.2.15"
        "198.51.100.0/24"
        "2001:db8::/32"
      ];
      description = ''
        The addresses and CIDRs that may open SSH connections to the host, or
        "any" for every source. Every host sets it. An item with a colon is
        IPv6. With a list, sshd is closed to every other source on IPv4 and
        on IPv6, and loopback always passes.
      '';
    };
    logOnly = mkOption {
      type = types.bool;
      default = false;
      description = ''
        With a list: keep sshd open to every source. Record each new
        connection from outside the list in the sets of table
        inet servacho-ssh-audit, for up to 14 days. A reload of
        nftables.service and a reboot empty the sets. Each deploy that
        changes an nftables table on the host reloads nftables.service.
      '';
    };
  };

  options.servacho.egress = {
    enable = mkEnableOption "the refusal of new connections from the host to private addresses";
    logOnly = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Record and log each connection the filter would refuse, and refuse
        nothing. In both modes, the sets refused4 and refused6 keep each
        destination for up to 14 days. A reload of nftables.service and a
        reboot empty them.
      '';
    };
    allow = mkOption {
      type = types.listOf addressType;
      default = [ ];
      example = [ "192.0.2.10" ];
      description = "Private addresses or CIDRs, IPv4 or IPv6, the host may reach on every port.";
    };
    allowTcp = mkOption {
      type = types.listOf portEntry;
      default = [ ];
      example = [
        {
          address = "192.0.2.10";
          ports = [ 8006 ];
        }
      ];
      description = "Private addresses or CIDRs, each with the TCP ports the host may reach on it.";
    };
    allowUdp = mkOption {
      type = types.listOf portEntry;
      default = [ ];
      description = "Private addresses or CIDRs, each with the UDP ports the host may reach on it.";
    };
    allowInterfaces = mkOption {
      type = types.listOf interfaceType;
      default = [ ];
      example = [ "br-*" ];
      description = "Interfaces whose traffic is not filtered, in addition to lo. nft wildcards work.";
    };
    extraRules = mkOption {
      type = types.lines;
      default = "";
      description = ''
        nft rules that accept, before the refusal. Postrouting uses them too,
        and postrouting cannot reject, so use no reject here.
      '';
    };
    blocked = mkOption {
      type = types.listOf addressType;
      default = [
        "10.0.0.0/8"
        "172.16.0.0/12"
        "192.168.0.0/16"
        "169.254.0.0/16"
        "224.0.0.0/4"
        "255.255.255.255"
        "fc00::/7"
        "fe80::/10"
        "ff00::/8"
      ];
      description = "The destinations the filter refuses. A definition replaces the whole list.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = ssh.sources != null;
          message = ''servacho.ssh.sources is not set. Set it to the addresses that may reach sshd, or to "any" to keep sshd open to every source.'';
        }
        {
          assertion = !sshList || ssh.sources != [ ];
          message = "servacho.ssh.sources is an empty list. Only the Proxmox console would reach this host.";
        }
        {
          assertion = !sshEnforced || !sshReopened;
          message = "servacho.ssh.sources is a list, but networking.firewall also opens an sshd port to every source (allowedTCPPorts, a port range, or interfaces.<name>).";
        }
        {
          assertion = !sshEnforced || (fw.enable && fw.backend == "nftables");
          message = "servacho.ssh.sources is a list, but the NixOS firewall is off or does not use nftables. The list is a rule in table nixos-fw, and the module takes the sshd port out of the open ports. Without nixos-fw, sshd is open to every source (firewall off) or closed to every source (iptables or firewalld). Use networking.firewall.enable = true and networking.nftables.enable = true, with no firewalld and no iptables backend.";
        }
        {
          assertion = !((sshList && ssh.logOnly) || egress.enable) || config.networking.nftables.enable;
          message = "servacho.ssh.logOnly and servacho.egress add tables to networking.nftables.tables, and only networking.nftables loads them. Enable networking.nftables.";
        }
        {
          assertion = !egress.enable || !dhcpOn;
          message = "servacho.egress needs a static address and DHCP off: DHCP renewals, and the DNS server DHCP gives, are private addresses.";
        }
      ];
    }
    (mkIf sshEnforced {
      services.openssh.openFirewall = false;
      networking.firewall.extraInputRules = lib.mkMerge [
        (
          rule (v4 ssh.sources) "ip saddr ${nftSet (v4 ssh.sources)} tcp dport ${nftSet sshPorts} accept"
          + rule (v6 ssh.sources) "ip6 saddr ${nftSet (v6 ssh.sources)} tcp dport ${nftSet sshPorts} accept"
        )
        # NixOS logs no refused connection by default (logRefusedConnections).
        # Last in input-allow, so it sees only the connections that no rule
        # accepted, which the chain's policy then drops.
        (lib.mkAfter ''
          tcp dport ${nftSet sshPorts} counter limit rate 6/minute log prefix "servacho-ssh-refused: " level info
        '')
      ];
    })
    (mkIf (sshList && ssh.logOnly) {
      networking.nftables.tables.servacho-ssh-audit = {
        family = "inet";
        content = sshAuditTable;
      };
    })
    (mkIf egress.enable {
      networking.nftables.tables.servacho-egress = {
        family = "inet";
        content = egressTable;
      };
      # LLMNR sends to 224.0.0.252 and ff02::1:3, which the filter refuses.
      services.resolved.settings.Resolve.LLMNR = lib.mkDefault "no";
    })
  ];
}
