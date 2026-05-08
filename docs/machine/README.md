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
  [rebuild it](../../mpd-machine/platforms/README.md), keep going.
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
| **macOS** (Apple Silicon) | UTM with QEMU backend | Use the [`platforms/macos-utm/`](../../mpd-machine/platforms/macos-utm/README.md) automated bootstrap — double-click `setup.command` to do VM creation + cloud-init + repo clone + `mpd` build + macOS networking (route, resolver, CA) in one shot, plus `start.command` / `stop.command` / `uninstall.command` for the lifecycle. QEMU+SPICE gives clipboard sync, dynamic display resize, and visible DHCP leases in UTM's GUI. |
| **Linux** | libvirt/KVM, QEMU, or anything you already drive | Follow [`platforms/generic-vm/`](../../mpd-machine/platforms/generic-vm/README.md). Five-step manual install from the netinst ISO. |
| **Windows** | Hyper-V (free with Windows Pro) | [`platforms/windows-hyperv/`](../../mpd-machine/platforms/windows-hyperv/README.txt) automated bootstrap — `setup.cmd` does VM creation + cloud-init + repo clone + `mpd` build + Windows networking in one shot. |
| **Cloud** | Hetzner Cloud, Hyperstack, AWS/GCP/Azure, etc. | Provision a Debian Trixie instance, follow [`platforms/generic-vm/`](../../mpd-machine/platforms/generic-vm/README.md). The "VM" can be a real cloud server. |

The mpd flow itself is identical regardless of hypervisor — pick whatever
you're comfortable driving.

## Bootstrap and setup

Two phases: get a VM ready, then run `mpd --setup` inside it.

1. **Pick a path** from
   [`mpd-machine/platforms/`](../../mpd-machine/platforms/README.md) —
   automated (`macos-utm/` or `windows-hyperv/`) or manual (`generic-vm/`).
   End state of any path: a Debian Trixie VM with `mpd` built and
   reachable over SSH.
2. **`mpd --setup`** inside the VM (interactive where system changes
   are required). Does the rest: CA + service certs, dnsmasq +
   systemd-resolved DNS for `*.mpd.test`, Podman network + data volume,
   always-on infra services (dnsmasq, portal, Adminer, fileaccess),
   and prints a per-OS laptop client recipe at the end (route + DNS +
   optional CA trust).

For the full operational handbook (day-to-day commands, project
lifecycle, SSH workflow), see [USAGE.md](USAGE.md).

## Setup info and client artifacts

- `mpd --setup` is idempotent and can be re-run any time.
- `mpd --setup-info` reprints the full plain-text laptop-side recipe
  (route + DNS + optional CA trust + verify + uninstall + delete-VM).
  Pipeable from your laptop:
  `ssh user@vm "mpd --setup-info" > SETUP.txt`.
- Project backups travel via fileaccess:
  `scp fileaccess.service.mpd.test:/srv/backups/<file>`. (Backup verbs
  themselves are on the [roadmap](../ROADMAP.md); today the runtime
  writes to `/srv/backups/`, you pull off via fileaccess.)
- Private keys are never printed to terminal output.
  `~/Developer/mpd/conf/` is canonical secret storage.

## Operational constraints

- No prebuilt binaries are stored in git; `mpd` is built in-VM.
- VM IP is recorded in `~/Developer/mpd/conf/platform.env` (set by the
  bootstrap script or by `provision-vm.sh`'s prompt; the macOS+UTM
  bootstrap prompts for the last IP octet on the vmnet shared bridge
  with default `158`, see
  [`platforms/macos-utm/README.md`](../../mpd-machine/platforms/macos-utm/README.md#why-the-vm-ip-is-pinned)).
- Laptop-side route + DNS resolver + CA trust are configured
  automatically by the platform setup scripts on macOS+UTM
  (`setup.command`) and Windows+Hyper-V (`setup.cmd`). On the
  generic-vm path (any other Linux / hand-built VM), they are manual —
  printed by `mpd --setup` and `mpd --setup-info` for the user to run.

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
- [`platforms/macos-utm/README.md`](../../mpd-machine/platforms/macos-utm/README.md)
  — automated UTM bootstrap on macOS + recovery
- [`platforms/windows-hyperv/README.txt`](../../mpd-machine/platforms/windows-hyperv/README.txt)
  — automated Hyper-V bootstrap on Windows
- [`platforms/generic-vm/README.md`](../../mpd-machine/platforms/generic-vm/README.md)
  — manual bootstrap on any Debian Trixie VM
