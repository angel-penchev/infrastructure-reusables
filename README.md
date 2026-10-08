# infrastructure-reusables

The NixOS modules, installer image and OpenTofu modules shared by every
management plane on servacho and by the organisations' own infrastructure
repositories. Nothing in it is specific to one machine, network or
organisation; those live in the repositories that use it.

| Repository | Owns | Applied from |
|---|---|---|
| [servacho-infrastructure](https://github.com/angel-penchev/servacho-infrastructure) | The Proxmox host, UniFi and VLANs, each organisation's pool and token, the root management plane and every organisation's plane | The root plane |
| `qoax-community/qoax-infrastructure` | Everything in Qoax Community's pool | Qoax Community's plane |
| an FMI{Codes} repository, when there is one | Everything in FMI{Codes}' pool | FMI{Codes}' plane |

All of them pin this repository by tag.

## NixOS modules

| Output | What it is |
|---|---|
| `nixosModules.base` | What every VM shares: SSH by key only, the QEMU guest agent, the nftables firewall, Nix housekeeping |
| `nixosModules.management-plane` | `servacho.managementPlane.*`: OpenTofu, OpenBao on loopback, an optional GitHub runner, an optional static address |
| `nixosModules.k3s-node` | `servacho.k3s.*`: a k3s server or agent with its firewall, flannel's backend (VXLAN or WireGuard), kubelet image garbage collection, and Longhorn's host side |
| `nixosModules.proxmox-guest` | The hardware and disko disk layout of a VM installed by `tofu/modules/nixos-vm`, data disks included (`servacho.proxmoxGuest.dataDisks`); brings disko with it |
| `nixosModules.installer` | `servacho.installer.*`: the ISO `nixos-vm` boots VMs from |

```nix
{
  inputs.reusables.url = "github:angel-penchev/infrastructure-reusables/v0.5.0";
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
  source     = "github.com/angel-penchev/infrastructure-reusables//tofu/modules/installer-iso?ref=v0.5.0"
  flake_attr = "${abspath("${path.module}/../nixos")}#installer-iso"
  iso_name   = "qoax-installer"
  node_name  = "Servacho-Gosho"
}

module "k3s_server" {
  source           = "github.com/angel-penchev/infrastructure-reusables//tofu/modules/nixos-vm?ref=v0.5.0"
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
      - uses: angel-penchev/infrastructure-reusables/actions/openbao-unseal@v0.5.0
        with:
          sealed_hint: servacho-infrastructure unseals it every 30 minutes.
      - uses: angel-penchev/infrastructure-reusables/actions/tofu-plan@v0.5.0
        with:
          vault_token: ${{ secrets.OPENBAO_TOKEN }}
```

`tofu-apply` takes the same inputs, plus `branch` for a manual run of a branch
or tag. `working_directory` (default `tofu`) selects the root module, and
`parallelism` (default 4) how many operations OpenTofu runs at once: each NixOS
host or ISO a plan reads is a Nix evaluation of up to about 0.75 GB, so it
bounds the plane's memory however many hosts the repository has.

## Checks

`nix flake check` builds an example management plane, k3s server and installer;
CI also checks formatting and validates the OpenTofu modules.

## Commit messages

Conventional Commits, checked locally by the hook in `.githooks` and in CI.
Enable the hook once after cloning:

```bash
sh scripts/setup-hooks.sh
```
