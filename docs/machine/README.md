# mpd-machine

`mpd-machine` is the **host-integrated** mode: a matched-host
bootstrap script (UTM on macOS, libvirt/KVM on Ubuntu, Hyper-V on
Windows) creates a Debian Trixie cloud-init VM, builds `mpd` inside
it, and configures the host's static route + DNS resolver + CA trust
so your laptop's own browser and IDE see `*.mpd.test` directly.
Containers run inside the VM under rootful Podman. The laptop runs
an IDE, a browser, an AI agent, a terminal — and SSH-or-https into
the VM.

For the simpler "live entirely inside the VM, host stays untouched"
flow, see the [Sandbox VM mode](../../setup/sandbox/README.md). For
the macOS-native flow without a hypervisor of your own, see
[mpd-desktop](../desktop/README.md). For the full pitch (why a VM,
why a sandbox, why SSH-everywhere), see [../VISION.md](../VISION.md).
This page is the "what is mpd-machine, when do I pick it, how do I
get a VM" reference.

## When to pick mpd-machine

Pick this mode if any of these apply:

- **You're on macOS, Ubuntu, or Windows and want native host
  integration.** Browser/IDE on the host see `*.mpd.test` directly
  (no need to open a VM window or SSH-tunnel browser traffic).
- **You want the AI agent to be able to do drastic things.** `rm -rf /`
  doesn't matter when the VM is throwaway — wreck it, rebuild it
  via the bootstrap script, keep going.
- **You don't want any container surface area on your primary
  machine.** The hypervisor is a strong boundary; containers,
  services, ports, and DNS all live on the other side of it.

If your host isn't one of the matched-host targets (you're on Fedora,
or any other Linux flavor, or you'd rather work inside the VM
window), pick [Sandbox VM](../../setup/sandbox/README.md) instead.

## Where mpd's invasive changes live — inside the VM

The matched-host bootstrap script creates a **dedicated Debian Trixie
VM** and that's where the invasive changes happen: passwordless sudo
for the dev user, apt-installed runtime stack (podman, dnsmasq, etc.),
CA in the system trust store, `systemd-resolved` drop-in for
`*.mpd.test`, rootful Podman networks/volumes. Treat that VM as
wipe-and-rebuild; don't repurpose it for unrelated work.

The host (your daily-driver macOS / Ubuntu / Windows) gets only
**scoped, reversible** changes: a route to the container subnet, a
DNS resolver drop-in for `*.mpd.test`, mpd's local CA in the trust
store, plus on Ubuntu+KVM the libvirt-related apt packages required
to drive the VM. All of it is reversible via the matching
`uninstall` script. Designed to coexist with daily-driver use — the
bootstrap is meant to run on the host you actually live on.

## Picking a bootstrap

mpd-machine ships a matched-host bootstrap for each of the three
supported hosts. End state of any path: a Debian Trixie VM with `mpd`
built and reachable, plus host-side networking (route + DNS resolver
+ CA trust) configured automatically.

| Host OS                   | Hypervisor                      | Bootstrap                                                                                                                                                                                                                                                        |
|---------------------------|---------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **macOS** (Apple Silicon) | UTM with QEMU backend           | [`setup/macos-utm/`](../../setup/macos-utm/README.md) — double-click `setup.command`. QEMU+SPICE gives clipboard sync, dynamic display resize, and visible DHCP leases in UTM's GUI. `start.command` / `stop.command` / `uninstall.command` cover the lifecycle. |
| **macOS** (Apple Silicon) | Parallels Desktop Pro           | [`setup/macos-prl/`](../../setup/macos-prl/README.md) — double-click `setup.command`. Clones a one-time-built Parallels template via `prlctl` and configures the result over SSH. Requires a Parallels Desktop Pro license.                                     |
| **Ubuntu 26.04 LTS**      | libvirt + KVM                   | [`setup/ubuntu-kvm/`](../../setup/ubuntu-kvm/README.md) — `bash setup.sh` for end-to-end VM creation + host networking + a desktop launcher in GNOME Activities. `start.sh` / `stop.sh` / `uninstall.sh` cover the lifecycle.                                    |
| **Windows**               | Hyper-V (free with Windows Pro) | [`setup/windows-hyperv/`](../../setup/windows-hyperv/README.txt) — `setup.cmd` does VM creation + cloud-init + repo clone + `mpd` build + Windows networking in one shot.                                                                                        |

Other hosts (Fedora, Arch, NixOS, cloud Debian instances, anywhere
the matched-host bootstrap doesn't apply) → use the
[Sandbox VM mode](../../setup/sandbox/README.md) instead. mpd's flow
inside the VM is identical regardless of how you got there.

## Bootstrap and setup

Two phases: the matched-host bootstrap creates the VM, then
`mpd --setup` runs inside it.

1. **Run the matched-host bootstrap** (`setup.command` /
   `setup.sh` / `setup.cmd` from `setup/<platform>/`). End state: a
   Debian Trixie VM with `mpd` on PATH, your laptop SSH key
   authorized, host-side route + DNS + CA trust applied.
2. **`mpd --setup`** inside the VM (interactive where system changes
   are required). Does the rest: CA + service certs, dnsmasq +
   systemd-resolved DNS for `*.mpd.test`, Podman network + data volume,
   always-on infra services (dnsmasq, portal, Adminer, fileaccess).

For the full operational handbook (day-to-day commands, project
lifecycle, SSH workflow), see [USAGE.md](USAGE.md).

## Setup info and client artifacts

- `mpd --setup` is idempotent and can be re-run any time.
- `mpd --setup-info` prints the platform identity plus a pointer to
  the platform's bootstrap README (where the host-side trust + route +
  resolver setup actually lives). Pipeable from your laptop:
  `ssh user@vm "mpd --setup-info" > SETUP.txt`.
- Project backups travel via fileaccess:
  `scp fileaccess.service.mpd.test:/srv/backups/<file>`. (Backup verbs
  themselves are on the [roadmap](../ROADMAP.md); today the runtime
  writes to `/srv/backups/`, you pull off via fileaccess.)
- Private keys are never printed to terminal output.
  `~/Developer/mpd/conf/` is canonical secret storage.

## Operational constraints

- No prebuilt binaries are stored in git; `mpd` is built in-VM.
- VM IP is recorded in `~/Developer/mpd/conf/platform.env` (set by
  the bootstrap script; the macOS+UTM bootstrap prompts for the last
  IP octet on the vmnet shared bridge with default `158`, see
  [`setup/macos-utm/README.md`](../../setup/macos-utm/README.md#why-the-vm-ip-is-pinned)).
- Laptop-side route + DNS resolver + CA trust are configured
  automatically by every matched-host setup script
  (macOS+UTM `setup.command`, Ubuntu+KVM `setup.sh`, Windows+Hyper-V
  `setup.cmd`). No manual host-side commands required.

## Directory model (in the VM)

- `~/Developer/mpd/bin/` — compiled `mpd`
- `~/Developer/mpd/conf/` — persistent CA + service cert material
  (`caroot/`, `service/`) + `platform.env`
- `~/.mpd/` — runtime state/cache only (recreated by `mpd --setup`,
  removed by `mpd --uninstall`)

`conf/wireguard/` is **not** used on machine mode; if a legacy
WG-based mpd-machine version was previously installed,
`mpd --uninstall` cleans up the directory and disables the legacy
`wg-quick@wg0.service` if present.

For full directory-contract detail (including data-volume layout under
`/srv/`), see [`../ARCHITECTURE.md` §4](../ARCHITECTURE.md#4-repository-directory-contract).

## Reference

- [USAGE.md](USAGE.md) — operational handbook (day-to-day, project
  lifecycle, SSH-into-runtime worked example)
- [NETWORKING.md](NETWORKING.md) — host ↔ VM ↔ container routing model,
  per-OS laptop recipes
- [SECURITY.md](SECURITY.md) — trust boundaries, intentional compromises
- [`setup/macos-utm/README.md`](../../setup/macos-utm/README.md)
  — UTM bootstrap on macOS + recovery
- [`setup/ubuntu-kvm/README.md`](../../setup/ubuntu-kvm/README.md)
  — libvirt/KVM bootstrap on Ubuntu 26.04 LTS
- [`setup/windows-hyperv/README.txt`](../../setup/windows-hyperv/README.txt)
  — Hyper-V bootstrap on Windows

For the related "live entirely inside a sandbox VM" mode, see
[`setup/sandbox/README.md`](../../setup/sandbox/README.md). For the
macOS-native (no VM you manage) mode, see
[`../desktop/README.md`](../desktop/README.md).
