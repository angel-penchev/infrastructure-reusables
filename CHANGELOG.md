# Changelog

The changes in each release that a consumer must know about. The GitHub
release of each tag has the same text.

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

## v0.9.1

### Fixes

- **The management plane's runner restarts however its unit ends.** The
  github-runner module restarts a runner only after its retryable exit code 2,
  and an ephemeral runner also after a clean exit. Thus a registration that
  failed or timed out in `ExecStartPre` left the unit failed until someone
  restarted it by hand.
  - The runner unit now has `Restart=always`, `RestartSec=30s` and no start
    rate limit. While GitHub is out of reach, the runner tries to register
    again every 30 seconds until it succeeds.
  - An ephemeral runner also waits these 30 seconds between jobs.
  - A stop with `systemctl`, or a shutdown, stays stopped.

### Upgrading

- Planes with the runner on get the new unit settings on their next deploy.
  Nothing else changes.

## v0.9.0

### New

- **`nixosModules.docker-host`** (`servacho.dockerHost.*`) is Docker with
  Compose and weekly pruning. It is for a VM whose owner runs a stack by hand,
  reverse proxy included. It has an optional static address (`network`).
  - Docker publishes a container's ports through DNAT in prerouting, past
    `networking.firewall`. Thus the module filters in an nftables table of its
    own, ahead of Docker's.
  - From the LAN, only `ingress.ports` (default `80` and `443`) are open, and
    only from `ingress.sources`. No other connection from the LAN reaches a
    container.
  - Ports that a container publishes on loopback stay open to the host itself.
- `nix flake check` also builds an example Docker host.

### Upgrading

- Nothing changes for existing hosts. The module does nothing until a host
  imports it and sets `servacho.dockerHost.enable`.

## v0.8.0

### New

- **`management-plane` `runner.ephemeral`** runs one job for each
  registration. After each job, the runner de-registers and the module wipes
  its state and work directories. Then the runner registers again. Thus
  nothing that a job leaves there meets the next job. `/var/lib/opentofu`
  stays.
  - It needs a personal access token in `tokenFile`. The token must manage the
    repository's runners (fine-grained: Administration read and write). A
    one-hour registration token does not work.
  - It is off by default.

### Fixes

- **`k3s-node` keeps networkd off the pod network's links.** A host `.network`
  file that matches `Type=ether` also matches every pod's veth. networkd then
  gave each veth the node's address and a default route, and took it out of
  `cni0`. As a result, no pod reached the API
  (qoax-community/qoax-infrastructure#9). The module now marks `veth*`, `cni0`
  and `flannel*` as unmanaged, in a file that sorts before the host's own
  files. It does nothing unless networkd is enabled.

### Upgrading

- Nothing changes on a management plane unless you set `runner.ephemeral`.
- k3s nodes get the new network file `00-k3s-cni` on their next deploy.

## v0.7.1

### Fixes

- **`extra_files` of `nixos-vm` works.** v0.6.0 and v0.7.0 shipped
  `extra-files.sh` without its executable bit. Thus nixos-anywhere refused to
  run it, and every install that set `extra_files` failed with
  `extra_files_script … is not executable`.
- CI now fails on each shell script that has no executable bit in the commit.

### Upgrading

- Move from v0.6.0 or v0.7.0 if you use `extra_files`. The next apply tries a
  failed install again.

## v0.7.0

### New

- **`nixos-vm` `memory_floating`** turns on Proxmox memory ballooning. Below
  `memory`, the guest's balloon driver hands idle memory back to the host when
  the host runs short, down to `memory_floating`.
  - It suits management planes, which need their memory only while a plan
    evaluates NixOS hosts.
  - 0, the default, keeps memory fixed, as a Kubernetes node wants.

### Upgrading

- Nothing changes unless you set `memory_floating`. Setting it changes the
  VM's memory configuration, which Proxmox applies at the next reboot.

## v0.6.0

### New

- **`nixos-vm` `data_disks`** attaches disks after the system disk (`virtio1`
  onwards). `backup = false` keeps a disk out of Proxmox backups.
- **`proxmox-guest` `servacho.proxmoxGuest.dataDisks`** mounts those disks
  (`/dev/vdb` onwards), each as one ext4 filesystem. At install, disko formats
  them, and they grow with the disk on the next boot.
- **`nixos-vm` `extra_files`** (sensitive, absolute path → content) puts files
  on the host at install through nixos-anywhere, such as a k3s join token in
  `/etc/rancher/k3s/config.yaml`. The content goes in the environment of the
  install script, not through the state or the Nix store. Files are 0600, and
  directories are 0755.
- **`k3s-node`**:
  - `imageGC = { highThreshold; lowThreshold; }` sets the thresholds of the
    kubelet's image garbage collection, for nodes that pull many short-lived
    images.
  - `flannelBackend` is `vxlan` (the default) or `wireguard-native`, and opens
    the matching port.
  - `apiSources` opens the API of a server (6443) to more sources, and nothing
    else.

### Fixes

- **A plan no longer uses all the memory of a plane.**
  - `actions/tofu-plan` and `actions/tofu-apply` run OpenTofu with
    `-parallelism 4` by default (new `parallelism` input). Each NixOS host or
    ISO that a plan reads is a Nix evaluation of up to about 0.75 GB. Thus
    this limit bounds the memory, however many hosts a repository has.
  - `nixosModules.management-plane` enables zram swap (50% of RAM).
- The commit hook now uses qoax-githooks v1.0.7.

### Upgrading

- Existing hosts do not change unless they set the new options. A management
  plane gets zram swap on its next deploy.
- `proxmox-guest` now declares an option, so its settings are under `config`.
  A host that imported it keeps the same disk layout.
- Give a plane enough memory for four evaluations at the same time, plus
  OpenBao and the runner. 8 GiB is enough.

## v0.5.0

### New

- **GitHub Actions for the workflows of the planes.** servacho-infrastructure
  and the repositories of the organisations share these composite actions:
  - `actions/openbao-unseal` unseals the OpenBao of the plane with
    `unseal_keys`. Without keys, it only checks the seal, and fails with
    `sealed_hint` when the plane is sealed.
  - `actions/tofu-plan` runs `tofu init` and `plan`, and posts the plan on the
    pull request. Each new plan replaces the last one, until an apply follows.
    Then the action fails if the plan failed.
  - `actions/tofu-apply` runs `tofu init` and `apply`, then posts the result
    on the pull request of the applied commit.

### Upgrading

- Use them with `uses:
  angel-penchev/infrastructure-reusables/actions/<name>@v0.5.0`. The runner
  needs `tofu`, `curl` and `jq`. The runner of `nixosModules.management-plane`
  has them. Restart a runner that started before v0.4.0, so that it gets
  `curl`.
- The NixOS and OpenTofu modules are the same as in v0.4.0.

## v0.4.0

### Fixes

- **installer-iso keeps the uploaded ISO safe from the garbage collector.**
  The provider `bpg/proxmox` reads the local file of the uploaded ISO on every
  refresh. After the Nix GC on the plane removed that file, every plan failed
  with `no such file or directory`. Two changes fix it:
  - A plan now realises the ISO. This also repairs a state whose ISO the GC
    removed already.
  - Each uploaded build keeps a GC root in the new `gc_root_dir` (default
    `/var/lib/opentofu/gcroots`) until a newer build replaces it.

### Upgrading

- You do not need to change the `module` block, unless the OpenTofu state
  directory of your runner is not `/var/lib/opentofu`.
- The first apply replaces `terraform_data.build` with
  `terraform_data.gc_root`, and keeps the uploaded ISO in place.
- If the ISO is not in the store, a plan can build it. That is about 1.5 GB,
  mostly from the binary cache.

## v0.3.0

### Features

- **The management-plane runner waits for its token.** Until its token file
  exists or the runner has a registration
  (`/var/lib/github-runner/<name>/.runner`), systemd skips
  `github-runner-<name>` and does not fail it. Thus you can deploy a plane
  with `servacho.managementPlane.runner.enable = true` before its registration
  token is in place. You can then supply the token later.
  servacho-infrastructure does this from its root plane. A runner with an
  existing registration does not change.
- **The runner has `curl`** on its path.

## v0.2.0

### Breaking

- **installer-iso follows the flake.** The `generation` variable is gone. The
  module builds the ISO again whenever its store path changes (nixpkgs, the
  keys it lets in, the installer module). It uploads each build as
  `<iso_name>-<hash>.iso`, moves the attached VMs onto it, and then deletes
  the previous one. Thus old ISOs do not stay on the storage. Remove
  `generation` from your `module` blocks. The first apply replaces the ISO
  that v0.1.0 uploaded.

### Fixes

- **nixos-vm reinstalls only when OpenTofu replaces the VM** (#2).
  `installation_id` no longer comes from the MAC address. Thus a VM that you
  restore from a backup under the same id keeps its disk. To reinstall on
  purpose, run `tofu apply
  -replace='module.<vm>.terraform_data.installation'`. **Do not move a VM that
  v0.1.0 already installed onto this release.** Its `installation_id` changes
  one time. Then nixos-anywhere would install it again and erase its disk.
  v0.1.0 installed no VM.
- **The installer's guest agent answers only after DHCP gives it an IPv4
  address.** Thus `nixos-vm` never uses the host's static address for the
  install before the installer has an address.

## v0.1.0

The first release: the modules every management plane on servacho, and the
organisations' own infrastructure repositories, are built from.

### NixOS modules

- `nixosModules.base`: SSH by key only, the QEMU guest agent, the nftables
  firewall, Nix housekeeping.
- `nixosModules.management-plane`: `servacho.managementPlane.*`, which covers
  OpenTofu, OpenBao on loopback, an optional GitHub runner and an optional
  static address.
- `nixosModules.k3s-node`: `servacho.k3s.*`, a k3s server or agent with its
  firewall and Longhorn's host side.
- `nixosModules.proxmox-guest`: the hardware and disko layout of a VM
  installed by `nixos-vm`.
- `nixosModules.installer`: `servacho.installer.*`, the ISO `nixos-vm` boots
  VMs from.

### OpenTofu modules

- `tofu/modules/installer-iso`: builds the installer from a flake and uploads
  it through the Proxmox API.
- `tofu/modules/nixos-vm`: takes a VM from an empty disk to a deployed host
  with nixos-anywhere.
