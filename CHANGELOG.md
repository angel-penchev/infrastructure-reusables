# Changelog

The changes in each release that a consumer must know about. Releases before
v0.10.0 have no entry here. Their tags and commits show what changed.

## v0.10.0

### Breaking

- Every host that imports `base`, `k3s-node` or `docker-host` must set
  `servacho.ssh.sources`. The evaluation fails until it does.

### Features

- `servacho.ssh.sources`: the IPv4 and IPv6 addresses and CIDRs that may open
  SSH connections to the host, or `"any"`. With a list, sshd is closed to
  every other source, and a rate-limited log line records each refused
  connection. A list needs the NixOS firewall with nftables.
- `servacho.ssh.logOnly`: with a list, sshd stays open, and table
  `inet servacho-ssh-audit` records each source outside the list.
- `servacho.egress`: an optional filter that refuses new connections from
  the host to private addresses. It has allowed addresses, address and port
  pairs, interfaces it does not judge, and a `logOnly` mode. A set records
  each refused destination.
- The sets of `logOnly` and of the egress filter keep each entry for up to
  14 days. Each reboot, and each deploy that changes an nftables table on
  the host, empties them. The journal keeps the log lines.
- `k3s-node` adds its pod interfaces and its peer ports to the egress filter.
  `docker-host` adds the Docker bridges.
- `tofu/modules/nixos-vm`: the input `started`, default `true`. With
  `false`, an apply shuts the VM down and later applies do not start it.
- Checks: `firewall-eval`, `nftables-rules`, `firewall-vm`, and three example
  systems with the new options. CI loads the nftables rules of each example
  into a kernel, and runs `firewall-vm`. The job fails if the runner has no
  KVM.

### Upgrading

1. Set `servacho.ssh.sources` on every host. The value `"any"` keeps sshd as
   it is, and with `"any"` and the egress filter off, the system does not
   change.
2. Move each pin to v0.10.0. Update the flake input alone
   (`nix flake update reusables`), so nixpkgs stays where it is.
3. Before a host gets a list, add its deployer to the list.
