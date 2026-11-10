# infrastructure-reusables

The NixOS modules, installer image and OpenTofu modules shared by every
management plane on servacho and by the organisations' own infrastructure
repositories. Nothing in it is specific to one machine, network or
organisation; those live in the repositories that use it.

| Repository | Owns | Applied from |
|---|---|---|
| [servacho-infrastructure](https://github.com/angel-penchev/servacho-infrastructure) | The Proxmox host, UniFi and VLANs, each organisation's pool and token, the root management plane and every organisation's plane | The root plane |
| `qoax-community/qoax-infrastructure` | Everything in Qoax's pool | Qoax's plane |
| a SUGAMING repository, when there is one | Everything in SUGAMING's pool | SUGAMING's plane |

All of them pin this repository by tag.

## NixOS modules

| Output | What it is |
|---|---|
| `nixosModules.base` | What every VM shares: SSH by key only and only from the sources the host sets (`servacho.ssh`), an optional egress filter (`servacho.egress`), the QEMU guest agent, the nftables firewall, Nix housekeeping |
| `nixosModules.management-plane` | `servacho.managementPlane.*`: OpenTofu, OpenBao on loopback, an optional GitHub runner, an optional static address |
| `nixosModules.k3s-node` | `servacho.k3s.*`: a k3s server or agent with its firewall, flannel's backend (VXLAN or WireGuard), kubelet image garbage collection, and Longhorn's host side |
| `nixosModules.docker-host` | `servacho.dockerHost.*`: Docker with Compose for a stack its owner runs by hand, reverse proxy included; an optional static address; the stack reachable from the LAN only on its ingress ports (`80`, `443`), and those only from the shared ingress |
| `nixosModules.proxmox-guest` | The hardware and disko disk layout of a VM installed by `tofu/modules/nixos-vm`, data disks included (`servacho.proxmoxGuest.dataDisks`); brings disko with it |
| `nixosModules.installer` | `servacho.installer.*`: the ISO `nixos-vm` boots VMs from |

```nix
{
  inputs.reusables.url = "github:angel-penchev/infrastructure-reusables/v0.10.0";
  inputs.nixpkgs.follows = "reusables/nixpkgs";
  # or: inputs.reusables.inputs.nixpkgs.follows = "nixpkgs";
}
```

A host installed by `nixos-vm` imports `base`, `proxmox-guest` and what it runs,
and sets its own static address. The installer needs the key of the plane that
installs from it, and is built from the consumer's flake:

```nix
nixosConfigurations.installer = nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  modules = [
    reusables.nixosModules.installer
    {
      servacho.installer.name = "qoax-installer";
      users.users.root.openssh.authorizedKeys.keyFiles = [ ./deploy-key.pub ];
    }
  ];
};
packages.x86_64-linux.installer-iso =
  self.nixosConfigurations.installer.config.system.build.isoImage;
```

A Docker host serves a Compose stack whose reverse proxy (Traefik, say) takes
the host's names from the shared ingress. Docker publishes a container's
ports through DNAT, past `networking.firewall`, so `docker-host` filters in
nftables tables of its own ahead of Docker's: `ingress.ports` only from
`ingress.sources`, and no other port of the stack from the LAN. Ports a
container publishes on loopback (`127.0.0.1:5432:5432`) stay reachable from
the host itself.

```nix
servacho.dockerHost = {
  enable = true;
  network = {
    address = "192.168.10.41";
    prefixLength = 23;
    gateway = "192.168.10.1";
  };
  ingress.sources = [ "192.168.4.16/32" ];
};
```

## SSH sources and egress

`base`, `k3s-node` and `docker-host` bring the options `servacho.ssh` and
`servacho.egress` (`nixos/modules/firewall.nix`). Every host sets
`servacho.ssh.sources`, and the evaluation fails until it does.

```nix
servacho.ssh.sources = [
  "192.0.2.15" # the management plane that deploys the host
  "198.51.100.0/24" # the administrators' network
];
servacho.egress = {
  enable = true;
  allowTcp = [
    {
      address = "10.0.0.10";
      ports = [ 8006 ];
    }
  ];
};
```

### `servacho.ssh`

| Option | Default | Meaning |
|---|---|---|
| `sources` | none, and the evaluation fails | A list of the IPv4 and IPv6 addresses and CIDRs that may open SSH connections, or `"any"`. The value `"any"` keeps sshd open to every source, as before v0.10.0. |
| `logOnly` | `false` | With a list: keep sshd open to every source, and record each new connection from outside the list. |

With a list, the firewall closes sshd to every other source, on IPv4 and on
IPv6. Loopback always passes. A counter and a log line, at most 6 a minute,
record the refused connections: `journalctl -k -g servacho-ssh-refused`. On a
k3s node, pods still reach sshd through the trusted pod interfaces.

The list is a rule in table `nixos-fw`. So the evaluation fails if the NixOS
firewall is off or does not use nftables (firewalld, or the iptables
backend). It also fails if `networking.firewall` opens an sshd port to every
source (`allowedTCPPorts`, a port range or `interfaces.<name>`).

With a list and `logOnly`, table `inet servacho-ssh-audit` keeps each source
from outside the list for up to 14 days:
`nft list set inet servacho-ssh-audit outside4` (and `outside6`). The log
line, at most 6 a minute, is in `journalctl -k -g servacho-ssh-outside`.
Read "Sets and reloads" below before you read an empty set as clean.

Two lists join. `"any"` and a list in two modules fail the evaluation.
`lib.mkDefault "any"` gives way to a list.

### `servacho.egress`

| Option | Default | Meaning |
|---|---|---|
| `enable` | `false` | Add table `inet servacho-egress`, which refuses new connections from the host to the `blocked` destinations. |
| `logOnly` | `false` | Record and log each connection the filter would refuse, and refuse nothing. |
| `allow` | `[ ]` | Private addresses or CIDRs, IPv4 or IPv6, that the host may reach on every port. |
| `allowTcp`, `allowUdp` | `[ ]` | Entries `{ address; ports; }`: a private address or CIDR, and the ports the host may reach on it. |
| `allowInterfaces` | `[ ]` | Interfaces the filter does not judge, in addition to `lo`. nft wildcards work (`"br-*"`). |
| `extraRules` | `""` | nft rules that accept, before the refusal. Postrouting uses them too, so use no `reject`. |
| `blocked` | `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `224.0.0.0/4`, `255.255.255.255`, `fc00::/7`, `fe80::/10`, `ff00::/8` | The refused destinations. A definition replaces the whole list. |

With `enable`:

- The filter allows the host's own DNS servers on TCP and UDP. The port is
  53, or the port in the entry. It reads `networking.nameservers`, the `dns` and
  `networkConfig.DNS` of each `systemd.network.networks` entry, and with
  systemd-resolved `services.resolved.settings.Resolve.DNS` and
  `FallbackDNS`. A DNS server set in another way, or DNS over TLS on port
  853, needs an `allowTcp` entry.
- LLMNR is off by default (`services.resolved.settings.Resolve.LLMNR`). It
  sends to multicast addresses that the filter refuses.
- The evaluation fails while the host uses DHCP. DHCP renewals, and the DNS
  server DHCP gives, are private addresses.
- `k3s-node` adds the pod interfaces. For each `clusterNetworks` entry, it
  also adds the peer ports: TCP 6443 and 10250, 2379-2380 on servers, and
  flannel's UDP port. A hostNetwork pod sends as the host, so put its private
  destinations in `allowTcp`.
- `docker-host` adds `docker0` and `br-*`, so that the host still reaches its
  containers. It also warns that the filter does not judge the containers.

The filter judges what the host itself sends. Forwarded traffic, from pods or
from containers on Docker bridges, passes. The filter refuses IGMP,
`224.0.0.0/24` and `ff02::/16` with no record. It limits a compromised
service, not root, which can delete the table.

A refused TCP connection fails at once, or at the first retransmit of its SYN
after about one second. The error is "No route to host" on IPv4 and
"Permission denied" on IPv6. The filter also refuses a connection to a
link-local IPv6 address, but the kernel does not tell the socket. So connect
waits until its timeout. A connection that nat output sends to a refused
address also waits until its timeout. Examples are a Kubernetes ClusterIP, or
a port that Docker publishes on the host's own address. Postrouting judges
these connections on their real destination, and drops them.

To see what the filter refused:

```bash
nft list set inet servacho-egress refused4 # and refused6
journalctl -k -g servacho-egress # the log, at most 6 lines a minute
```

### Sets and reloads

The sets `outside4`, `outside6`, `refused4` and `refused6` keep each entry
for 14 days, but only until nftables.service loads the rules again. Each
load deletes the tables and adds them again, and this empties the sets. A
load comes with each reboot, and with each deploy that changes an nftables
table on the host. The journal keeps the log lines across a load.

Before you read an empty set as clean, find when the rules were last loaded:

```bash
journalctl -u nftables.service -g 'Finished|Reloaded'
```

If a load came during the period you audit, also read the log for that
period: `journalctl -k -g servacho-ssh-outside` or
`journalctl -k -g servacho-egress`.

### Upgrading to v0.10.0

1. Set `servacho.ssh.sources` on every host that imports `base`, `k3s-node`
   or `docker-host`. The value `"any"` keeps sshd as it is. With `"any"` and
   the egress filter off, the system does not change. Each example that
   v0.9.1 also has evaluates to the same system as with v0.9.1.
2. Before a host gets a list, add its deployer to the list. The deployer is
   the management plane that deploys the host. Without it, the next deploy
   fails.
3. Turn the egress filter on with `logOnly = true` first. Read `refused4` and
   the log (see "Sets and reloads"), add what the host needs, then enforce
   it.

## OpenTofu modules

Both use the `bpg/proxmox` provider from the caller, through the Proxmox API
only: the provider needs no SSH to the node.

`tofu/modules/installer-iso` builds the installer from a flake and uploads it
to a Proxmox storage. Whenever its store path changes (a nixpkgs bump, a new
key, a change to the installer) it uploads it as `<iso_name>-<hash>.iso`, moves
the VMs that have the old one attached onto it, and deletes the old one. The
provider reads the uploaded file on every refresh, so a plan realises the ISO
(building it only when it is new or was garbage-collected), and each uploaded
build keeps a garbage collector root in `gc_root_dir` (default
`/var/lib/opentofu/gcroots`, the plane runner's state directory) until it has
been replaced.

`tofu/modules/nixos-vm` takes a VM from nothing to a deployed host: an empty
disk, the installer, nixos-anywhere with the host's disko layout, a reboot onto
the static address, and from then on every change to the host deployed in
place. The install runs once per VM that OpenTofu creates; `installation_id`
changes exactly when it runs again, for one-off setup that has to follow it.

`memory_floating` below `memory` turns on ballooning: the guest hands idle
memory back to the host under pressure, down to that much. It suits a
management plane, whose plans need memory only now and then; leave it at 0 for
a Kubernetes node.

`started = false` shuts the VM down at the next apply and keeps it off. The
provider reads the power state back. Without `started`, every apply starts a VM
that was shut down by hand. Set `on_boot = false` with it, so a restart of the
Proxmox node does not start the VM either. A new VM needs `started = true`,
because the install runs on the started installer. While the VM is off, a
change to its host configuration fails the deploy.

`data_disks` attaches disks after the system disk, `/dev/vdb` onwards, which
the host mounts through `servacho.proxmoxGuest.dataDisks` (one ext4 filesystem
per disk, grown with it). `extra_files` places files the host's configuration
must not hold, such as a k3s cluster token, at install: they travel to the
install script in its environment, not through the state or the Nix store, and
a later change reaches the host only through a reinstall.

A VM restored from a backup is left alone: restore it under the same id, with
any MAC address, and the next apply deploys the current configuration onto it
without reinstalling. To reinstall a VM on purpose:

```bash
tofu apply -replace='module.<name>.terraform_data.installation'
```

```hcl
module "installer" {
  source     = "github.com/angel-penchev/infrastructure-reusables//tofu/modules/installer-iso?ref=v0.10.0"
  flake_attr = "${abspath("${path.module}/../nixos")}#installer-iso"
  iso_name   = "qoax-installer"
  node_name  = "Servacho-Gosho"
}

module "k3s_server" {
  source           = "github.com/angel-penchev/infrastructure-reusables//tofu/modules/nixos-vm?ref=v0.10.0"
  name             = "qoaxhack-prod-1"
  node_name        = "Servacho-Gosho"
  vm_id            = 10031
  pool_id          = "pool-qoax-community"
  vlan_id          = 10
  installer_iso_id = module.installer.file_id
  flake            = abspath("${path.module}/../nixos")
  host             = "qoaxhack-prod-1"
  address          = "192.168.10.31"
  ssh_private_key  = data.vault_kv_secret_v2.deploy_key.data["private_key"]
  data_disks       = [{ size = 100, backup = false }] # Longhorn's
  extra_files = {
    "/etc/rancher/k3s/config.yaml" = "token: ${random_password.k3s.result}\ncluster-init: true\n"
  }
}
```

The runner applying these needs Nix with flakes, `jq` and `ssh` on its path;
`nixosModules.management-plane`'s runner has them.

## GitHub Actions

Composite actions for the workflows that run on a plane's runner. They need
`tofu`, `curl` and `jq` there; `nixosModules.management-plane`'s runner has
them.

| Action | What it does |
|---|---|
| `actions/openbao-unseal` | Unseals the plane's OpenBao with `unseal_keys`, or only checks the seal without them. A job that cannot read OpenBao fails here, with the reason |
| `actions/tofu-plan` | `tofu init` and `plan`; on a pull request, posts the plan as a comment, replacing the last plan until an apply comes after it |
| `actions/tofu-apply` | `tofu init` and `apply`; posts the outcome on the pull request the applied commit belongs to |

Plan and apply share the comment format, so a pull request's thread reads as
plan, apply, plan. A failed plan or apply is posted first, then fails the job.

```yaml
permissions:
  contents: read
  pull-requests: write

concurrency:
  group: tofu-state # the state is local to the plane
  cancel-in-progress: false

jobs:
  plan:
    runs-on: [self-hosted, qoax-community-management-plane]
    steps:
      - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5.1.0
      - uses: angel-penchev/infrastructure-reusables/actions/openbao-unseal@v0.10.0
        with:
          sealed_hint: servacho-infrastructure unseals it every 30 minutes.
      - uses: angel-penchev/infrastructure-reusables/actions/tofu-plan@v0.10.0
        with:
          vault_token: ${{ secrets.OPENBAO_TOKEN }}
```

`tofu-apply` takes the same inputs, plus `branch` for a manual run of a branch
or tag. `working_directory` (default `tofu`) selects the root module, and
`parallelism` (default 4) how many operations OpenTofu runs at once: each NixOS
host or ISO a plan reads is a Nix evaluation of up to about 0.75 GB, so it
bounds the plane's memory however many hosts the repository has.

## Checks

`nix flake check` builds the example systems in `flake.nix` and runs the
other checks. The examples are a management plane, a Docker host, an egress
host and the installer. There is also a k3s server and a k3s agent, each with
and without the egress filter.

- `firewall-eval`: evaluation only. It makes sure that each assertion in
  `firewall.nix` fails where it must and nowhere else. It also checks how the
  options merge, which addresses the options accept, and the text of the
  generated rules. Its evaluation prints one warning from nixpkgs, about a
  merge of an `either` type. The case where `"any"` and a list conflict
  causes it, and the warning is expected.
- `nftables-rules`: the nftables script of each example. The build checks
  each script with `nft --check` under LKL only, which can accept a rule that
  the kernel refuses. So CI also runs each script as root in a new network
  namespace, two times.
- `firewall-vm`: a NixOS test with three VMs. A target has an SSH list and
  the egress filter, and two clients are in the list or not. The test
  connects to SSH from both clients, and from the target to allowed and
  refused destinations on IPv4 and IPv6. Then it reloads nftables.service.
  It needs KVM, so CI runs it in its own job, and the job fails if
  `/dev/kvm` is not usable.

CI also checks formatting and validates the OpenTofu modules. To run one
check: `nix build -L .#checks.x86_64-linux.firewall-vm`.

## Commit messages

Conventional Commits, checked locally by the hook in `.githooks` and in CI.
Enable the hook once after cloning:

```bash
sh scripts/setup-hooks.sh
```
