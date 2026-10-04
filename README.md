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
| `nixosModules.k3s-node` | `servacho.k3s.*`: a k3s server or agent with its firewall and Longhorn's host side |
| `nixosModules.proxmox-guest` | The hardware and disko disk layout of a VM installed by `tofu/modules/nixos-vm`; brings disko with it |
| `nixosModules.installer` | `servacho.installer.*`: the ISO `nixos-vm` boots VMs from |

```nix
{
  inputs.reusables.url = "github:angel-penchev/infrastructure-reusables/v0.2.0";
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
to a Proxmox storage. A plan only evaluates its store path; whenever that
changes (a nixpkgs bump, a new key, a change to the installer) the apply builds
it and uploads it as `<iso_name>-<hash>.iso`, moves the VMs that have the old
one attached onto it, and deletes the old one.

`tofu/modules/nixos-vm` takes a VM from nothing to a deployed host: an empty
disk, the installer, nixos-anywhere with the host's disko layout, a reboot onto
the static address, and from then on every change to the host deployed in
place. The install runs once per VM that OpenTofu creates; `installation_id`
changes exactly when it runs again, for one-off setup that has to follow it.

A VM restored from a backup is left alone: restore it under the same id, with
any MAC address, and the next apply deploys the current configuration onto it
without reinstalling. To reinstall a VM on purpose:

```bash
tofu apply -replace='module.<name>.terraform_data.installation'
```

```hcl
module "installer" {
  source     = "github.com/angel-penchev/infrastructure-reusables//tofu/modules/installer-iso?ref=v0.2.0"
  flake_attr = "${abspath("${path.module}/../nixos")}#installer-iso"
  iso_name   = "qoax-installer"
  node_name  = "Servacho-Gosho"
}

module "k3s_server" {
  source           = "github.com/angel-penchev/infrastructure-reusables//tofu/modules/nixos-vm?ref=v0.2.0"
  name             = "qoaxhack-prod-1"
  node_name        = "Servacho-Gosho"
  vm_id            = 10021
  pool_id          = "pool-qoax-community"
  vlan_id          = 10
  installer_iso_id = module.installer.file_id
  flake            = abspath("${path.module}/../nixos")
  host             = "qoaxhack-prod-1"
  address          = "192.168.10.21"
  ssh_private_key  = data.vault_kv_secret_v2.deploy_key.data["private_key"]
}
```

The runner applying these needs Nix with flakes, `jq` and `ssh` on its path;
`nixosModules.management-plane`'s runner has them.

## Checks

`nix flake check` builds an example management plane, k3s server and installer;
CI also checks formatting and validates the OpenTofu modules.

## Commit messages

Conventional Commits, checked locally by the hook in `.githooks` and in CI.
Enable the hook once after cloning:

```bash
sh scripts/setup-hooks.sh
```
