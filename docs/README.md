# mpd Documentation

Index for the `mpd` documentation tree. New here? Start with the top-level
[`../README.md`](../README.md) for the pitch and the mode picker, then
come back here once you've decided which mode to install.

Three modes — Sandbox VM, **mpd-machine** (host-integrated cloud-init
VM), **mpd-desktop** (native Podman Desktop on macOS). Same CLI, same
URLs, switch without relearning.

## Reading order

If you're installing mpd for the first time:

1. [`../README.md`](../README.md) — overview and mode picker.
2. The bootstrap doc that fits the mode you picked — see the three
   sections below.
3. [`machine/USAGE.md`](machine/USAGE.md) for the universal day-to-day
   handbook (project lifecycle, SSH-into-runtime, tools) — the `mpd`
   CLI is identical across all three modes once installed.
4. Optional, on-demand: `NETWORKING.md`, `SECURITY.md`, `ARCHITECTURE.md`.

[`VISION.md`](VISION.md) covers the origin and design principles.

## Mode 1 — Sandbox VM (you live inside the VM)

Full GNOME desktop inside the VM. Install Debian Trixie with the
GNOME desktop in any hypervisor, snapshot, run one script inside the
VM. GNOME terminal runs `mpd`; GNOME Firefox-ESR sees `mpd.test`.
Host stays untouched. Lowest friction.

- [`../setup/sandbox/README.md`](../setup/sandbox/README.md) — install,
  prerequisites (hostname rename), revert.

## Mode 2 — mpd-machine (you stay on your host; SSH into a headless VM)

Automated headless Debian Trixie VM. The matched-host bootstrap
creates the VM, builds `mpd`, and configures host-side networking +
DNS + CA trust. Host browser visits `*.mpd.test` directly; host
terminal SSH'es into the VM to run the `mpd` CLI; your IDE
(PHPStorm Gateway / VSCode Remote-SSH) SSH'es one hop further into
the runtime container inside the VM.

- [`machine/README.md`](machine/README.md) — what mpd-machine is, when to pick it, picking a hypervisor
- [`machine/USAGE.md`](machine/USAGE.md) — bootstrap, setup, first project, day-to-day (universal handbook)
- [`machine/NETWORKING.md`](machine/NETWORKING.md) — host ↔ VM ↔ container routing model, per-OS laptop recipes
- [`machine/SECURITY.md`](machine/SECURITY.md) — trust boundaries
- Per-platform bootstrap:
  - [`../setup/macos/README.md`](../setup/macos/README.md) — Parallels Desktop Pro on macOS
  - [`../setup/linux/README.md`](../setup/linux/README.md) — libvirt/KVM on Ubuntu
  - [`../setup/windows/README.txt`](../setup/windows/README.txt) — Hyper-V on Windows

## Mode 3 — mpd-desktop (native macOS binary in your local Terminal)

`mpd` is a native macOS binary you run directly in your local
Terminal — no SSH hop. macOS browser sees `*.mpd.test` via a
WireGuard tunnel; Podman Desktop manages the Linux container machine
in the background. No hypervisor to drive yourself.

- [`desktop/README.md`](desktop/README.md) — what mpd-desktop is, when to pick it, prerequisites
- [`desktop/USAGE.md`](desktop/USAGE.md) — install, setup, first project, day-to-day
- [`desktop/NETWORKING.md`](desktop/NETWORKING.md) — gvproxy / WireGuard / dnsmasq design
- [`desktop/SECURITY.md`](desktop/SECURITY.md) — trust boundaries

## Vision and direction

- [`VISION.md`](VISION.md) — *Why mpd* — origin lineage, design principles, what working with mpd feels like
- [`ROADMAP.md`](ROADMAP.md) — what's queued next (`mdl-backup` / `mdl-restore` tools) and parked ideas

## Reference

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — repository architecture, mode split, networking summary, configuration model
- [`CLI_BEHAVIOR.md`](CLI_BEHAVIOR.md) — CLI behavior contract
- [`HOOKS.md`](HOOKS.md) — typed `Event` lifecycle hooks: events, audiences, asset-side `hooks/<event>.d/` scripts

## Shared host directory model

- `~/Developer/mpd/bin/` — local built binary output
- `~/Developer/mpd/conf/` — persistent local trust/network material
  (`caroot/`, `service/`, `temp/`, `platform.env`; plus `wireguard/`
  on mpd-desktop)
- `~/.mpd/` — runtime state and cache (recreated by `mpd --setup`,
  removed by `mpd --uninstall`)

Project backups live inside the data volume at `/srv/backups/` and are
pulled off via fileaccess SSH/scp before wiping. Full contract:
[`ARCHITECTURE.md` §10](ARCHITECTURE.md#10-backup-persistence).
