# mpd-machine

`mpd-machine` runs the full mpd container stack inside a **Linux
sandbox VM** that you reach from your laptop over a static route. The
VM is the wall: nothing dev-related ever touches your host. The laptop
runs an IDE, a browser, an AI agent, a terminal — and SSH-or-https into
the VM. That's it.

For the full pitch (why a VM, why a sandbox, why SSH-everywhere), see
[../VISION.md](../VISION.md). This page is the "what is it, when do I
pick it, how do I get a VM" reference.

## When to pick mpd-machine

Pick this mode if any of these apply:

- **You're not on macOS.** `mpd-desktop` is macOS-only;
  `mpd-machine` works from macOS, Linux, Windows, or a cloud-hosted dev
  laptop.
- **You want the AI agent to be able to do drastic things.** `rm -rf /`
  doesn't matter when the VM is throwaway — wreck it,
  [rebuild it](../../setup/README.md), keep going.
- **You don't want any container surface area on your primary
  machine.** The hypervisor is a strong boundary; containers,
  services, ports, and DNS all live on the other side of it.

## Intended environment — Linux sandbox

mpd-machine is for a **Linux box you treat as throwaway**: a VM, a
dedicated dev box, or a cloud instance you can wipe and rebuild without
consequence. mpd installs apt packages, drops a CA into the system trust
store, configures `systemd-resolved` for `*.mpd.test`, creates Podman
networks/volumes, and runs containers under rootful Podman. The system
changes are **not** designed to coexist with other work, and removal is
best-effort.

Run mpd-machine on:

- a UTM/QEMU/Lima/Hyper-V/KVM/etc. VM dedicated to mpd development.
- a remote dev box (cloud VM, lab box) you use exclusively for this
  purpose.
- bare hardware allocated as a sandbox (a spare laptop set aside for
  mpd).

Do **not** run mpd-machine on your primary Linux workstation alongside
other work.

## Picking a hypervisor

Any hypervisor that boots a Debian Trixie netinst ISO works. Concrete
recommendations per host OS:

| Host OS | Recommended | Notes |
|---|---|---|
| **macOS** (Apple Silicon) | UTM with QEMU backend | Use the [`platforms/macos-utm/`](../../setup/macos-utm/README.md) automated bootstrap — double-click `setup.command` to do VM creation + cloud-init + repo clone + `mpd` build + macOS networking (route, resolver, CA) in one shot, plus `start.command` / `stop.command` / `uninstall.command` for the lifecycle. QEMU+SPICE gives clipboard sync, dynamic display resize, and visible DHCP leases in UTM's GUI. |
| **Ubuntu 26.04 LTS** | libvirt + KVM | [`platforms/ubuntu-kvm/`](../../setup/ubuntu-kvm/README.md) automated bootstrap — `bash setup.sh` for end-to-end VM creation + cloud-init + repo clone + `mpd` build + Linux host networking (route, resolved drop-in, system trust, Firefox policies, NSS DB) and a desktop launcher in GNOME Activities. `start.sh` / `stop.sh` / `uninstall.sh` cover the lifecycle. |
| **Other Linux** | libvirt/KVM, QEMU, VirtualBox, VMware… | Install Ubuntu 26.04 desktop in your hypervisor and follow [`platforms/sandbox/`](../../setup/sandbox/README.md) — one script inside the VM, host stays untouched. |
| **Windows** | Hyper-V (free with Windows Pro) | [`platforms/windows-hyperv/`](../../setup/windows-hyperv/README.txt) automated bootstrap — `setup.cmd` does VM creation + cloud-init + repo clone + `mpd` build + Windows networking in one shot. Or follow [`platforms/sandbox/`](../../setup/sandbox/README.md) inside any Windows hypervisor. |
| **Cloud** | Hetzner Cloud, Hyperstack, AWS/GCP/Azure, etc. | Provision an Ubuntu 26.04 instance and follow [`platforms/sandbox/`](../../setup/sandbox/README.md). The "VM" can be a real cloud server (the hostname-rename gate still applies). |

The mpd flow itself is identical regardless of hypervisor — pick whatever
you're comfortable driving.

## Bootstrap and setup

Two phases: get a VM ready, then run `mpd --setup` inside it.

1. **Pick a path** from
   [`setup/`](../../setup/README.md) —
   one of the host-driven cloud-init platforms (`macos-utm/`,
   `ubuntu-kvm/`, `windows-hyperv/`) or the in-VM
   [`sandbox/`](../../setup/sandbox/README.md).
   End state of any path: a VM with `mpd` built and reachable.
2. **`mpd --setup`** inside the VM (interactive where system changes
   are required). Does the rest: CA + service certs, dnsmasq +
   systemd-resolved DNS for `*.mpd.test`, Podman network + data volume,
   always-on infra services (dnsmasq, portal, Adminer, fileaccess).
   On the cloud-init platforms it also prints a per-OS laptop client
   recipe (route + DNS + optional CA trust); on sandbox there is no
   separate laptop side, so this is skipped.

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
  [`platforms/macos-utm/README.md`](../../setup/macos-utm/README.md#why-the-vm-ip-is-pinned);
  sandbox leaves it empty since the VM IP is whatever the hypervisor
  hands out and nothing on the host queries `*.mpd.test`).
- Laptop-side route + DNS resolver + CA trust are configured
  automatically by every cloud-init platform's setup script
  (macOS+UTM `setup.command`, Ubuntu+KVM `setup.sh`, Windows+Hyper-V
  `setup.cmd`). The sandbox platform has no laptop-side configuration
  by design — the host runs the hypervisor; that's it.

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
- [`platforms/macos-utm/README.md`](../../setup/macos-utm/README.md)
  — automated UTM bootstrap on macOS + recovery
- [`platforms/ubuntu-kvm/README.md`](../../setup/ubuntu-kvm/README.md)
  — automated libvirt/KVM bootstrap on Ubuntu 26.04 LTS
- [`platforms/windows-hyperv/README.txt`](../../setup/windows-hyperv/README.txt)
  — automated Hyper-V bootstrap on Windows
- [`platforms/sandbox/README.md`](../../setup/sandbox/README.md)
  — graphical "live in the VM" Ubuntu 26.04 sandbox
