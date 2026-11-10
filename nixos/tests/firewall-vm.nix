# nixos/modules/firewall.nix on the NixOS kernel, in three VMs on one VLAN:
# target has an SSH source list and the egress filter, listed is in that list
# and serves TCP 80 and 81, unlisted is not in the list.
{ pkgs, self }:
pkgs.testers.runNixOSTest (
  { nodes, ... }:
  let
    listed4 = nodes.listed.networking.primaryIPAddress;
    listed6 = nodes.listed.networking.primaryIPv6Address;
    target4 = nodes.target.networking.primaryIPAddress;
    target6 = nodes.target.networking.primaryIPv6Address;
    # A private IPv6 address on the VLAN, which the filter refuses unless a
    # pair allows it.
    listedUla = "fd00:1::1";
  in
  {
    name = "servacho-firewall";

    nodes.target =
      { config, ... }:
      {
        imports = [ self.nixosModules.base ];
        # The test network gives eth1 static addresses.
        networking.useDHCP = false;
        networking.interfaces.eth1.ipv6.addresses = [
          {
            address = "fd00:1::2";
            prefixLength = 64;
          }
        ];
        servacho.ssh.sources = [
          listed4
          listed6
        ];
        servacho.egress = {
          enable = true;
          # A wildcard, as docker-host adds, so this kernel loads one.
          allowInterfaces = [ "br-*" ];
          allowTcp = [
            {
              address = listed4;
              ports = [ 80 ];
            }
            {
              address = listedUla;
              ports = [ 80 ];
            }
          ];
        };
        # As kube-proxy or Docker do: nat output sends a connection to the
        # host's own address to another host.
        networking.nftables.tables.test-dnat = {
          family = "ip";
          content = ''
            chain output {
              type nat hook output priority dstnat; policy accept;
              ip daddr ${config.networking.primaryIPAddress} tcp dport 8080 dnat to ${listed4}:81
              ip daddr ${config.networking.primaryIPAddress} tcp dport 8081 dnat to ${listed4}:80
            }
          '';
        };
      };

    nodes.listed =
      { lib, pkgs, ... }:
      {
        networking.interfaces.eth1.ipv6.addresses = [
          {
            address = listedUla;
            prefixLength = 64;
          }
        ];
        networking.firewall.allowedTCPPorts = [
          80
          81
        ];
        systemd.services = lib.genAttrs [ "listen-80" "listen-81" ] (name: {
          wantedBy = [ "multi-user.target" ];
          script = "exec ${pkgs.socat}/bin/socat TCP6-LISTEN:${lib.removePrefix "listen-" name},ipv6only=0,fork,reuseaddr SYSTEM:'echo hello'";
        });
      };

    nodes.unlisted = { };

    testScript = ''
      def connect(machine, host, port):
          """0: connected. 1: refused with an error. 124: no answer in 5 seconds."""
          status, _ = machine.execute(f"timeout 5 bash -c '</dev/tcp/{host}/{port}'")
          return status

      start_all()
      target.wait_for_unit("nftables.service")
      target.wait_for_unit("sshd.service")
      listed.wait_for_open_port(80)
      listed.wait_for_open_port(81)
      unlisted.wait_for_unit("multi-user.target")

      with subtest("sshd answers the listed client only, on IPv4 and IPv6"):
          assert connect(listed, "${target4}", 22) == 0
          assert connect(listed, "${target6}", 22) == 0
          assert connect(unlisted, "${target4}", 22) == 124
          assert connect(unlisted, "${target6}", 22) == 124
          target.wait_until_succeeds(
              "test $(journalctl -k --no-pager | grep -c 'servacho-ssh-refused: .*DPT=22') -gt 0"
          )

      with subtest("an allowed pair passes, another private port is refused with an error"):
          assert connect(target, "${listed4}", 80) == 0
          assert connect(target, "${listed4}", 81) == 1

      with subtest("IPv6: a pair passes after neighbour discovery, link-local is refused"):
          assert connect(target, "${listedUla}", 80) == 0
          assert connect(target, "${listedUla}", 81) == 1
          assert connect(target, "${listed6}", 81) == 0
          link_local = listed.succeed(
              "ip -6 -o addr show dev eth1 scope link | awk '{print $4}' | cut -d/ -f1"
          ).strip()
          # Refused too, but the kernel does not give the socket an ICMPv6
          # error for a link-local destination, so connect waits.
          assert connect(target, f"{link_local}%eth1", 80) == 124

      with subtest("nat output to the own address is judged after the rewrite"):
          assert connect(target, "${target4}", 8081) == 0
          assert connect(target, "${target4}", 8080) == 124

      with subtest("refused destinations are in the sets"):
          refused4 = target.succeed("nft list set inet servacho-egress refused4")
          assert "${listed4} . tcp . 81" in refused4, refused4
          assert "${listed4} . tcp . 80" not in refused4, refused4
          refused6 = target.succeed("nft list set inet servacho-egress refused6")
          assert "${listedUla} . tcp . 81" in refused6, refused6
          assert f"{link_local} . tcp . 80" in refused6, refused6
          target.succeed("test $(journalctl -k --no-pager | grep -c 'servacho-egress: ') -gt 0")

      with subtest("a reload of nftables.service empties the sets, the journal keeps the log"):
          target.succeed("systemctl reload nftables.service")
          loads = "journalctl -u nftables.service -g 'Finished|Reloaded' --no-pager"
          target.wait_until_succeeds(f"{loads} | grep 'Reloaded nftables firewall'", timeout=60)
          target.succeed(f"{loads} | grep 'Finished nftables firewall'")
          refused4 = target.succeed("nft list set inet servacho-egress refused4")
          assert "elements" not in refused4, refused4
          target.succeed("test $(journalctl -k --no-pager | grep -c 'servacho-egress: ') -gt 0")
    '';
  }
)
