# mpd Documentation

Index for the `mpd` documentation tree. New here? Start with the top-level
[`../README.md`](../README.md) for the pitch and the mode picker, then
come back here once you've decided which mode to install.

Naming convention across docs: **mpd-desktop** and **mpd-machine**
(hyphenated).

## Reading order

If you're installing mpd for the first time:

1. [`../README.md`](../README.md) — overview and mode picker.
2. The mode README that fits your host — [`desktop/README.md`](desktop/README.md) or [`machine/README.md`](machine/README.md).
3. The matching `USAGE.md` — install, first project, day-to-day commands.
4. Optional, on-demand: `NETWORKING.md`, `SECURITY.md`, `ARCHITECTURE.md`.

[`VISION.md`](VISION.md) covers the origin and design principles.

## mpd-desktop — native macOS

- [`desktop/README.md`](desktop/README.md) — what mpd-desktop is, when to pick it, prerequisites
- [`desktop/USAGE.md`](desktop/USAGE.md) — install, setup, first project, day-to-day
- [`desktop/NETWORKING.md`](desktop/NETWORKING.md) — gvproxy / WireGuard / dnsmasq design
- [`desktop/SECURITY.md`](desktop/SECURITY.md) — trust boundaries

## mpd-machine — Linux sandbox VM

- [`machine/README.md`](machine/README.md) — what mpd-machine is, when to pick it, picking a hypervisor
- [`machine/USAGE.md`](machine/USAGE.md) — bootstrap, setup, first project, day-to-day
- [`machine/NETWORKING.md`](machine/NETWORKING.md) — host ↔ VM ↔ container routing model, per-OS laptop recipes
- [`machine/SECURITY.md`](machine/SECURITY.md) — trust boundaries

Plus the bootstrap docs under
[`../mpd-machine/platforms/`](../mpd-machine/platforms/README.md):

- [`platforms/macos-utm/`](../mpd-machine/platforms/macos-utm/README.md)
  — automated UTM bootstrap (macOS)
- [`platforms/windows-hyperv/`](../mpd-machine/platforms/windows-hyperv/README.txt)
  — automated Hyper-V bootstrap (Windows)
- [`platforms/generic-vm/`](../mpd-machine/platforms/generic-vm/README.md)
  — manual bootstrap on any Debian Trixie VM (libvirt/KVM, QEMU, cloud, etc.)

## Vision and direction

- [`VISION.md`](VISION.md) — *Why mpd* — origin lineage, design principles, what working with mpd feels like
- [`ROADMAP.md`](ROADMAP.md) — what's queued next (`mpd <project> publish`, `mdl-backup` / `mdl-restore` tools)

## Reference

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — repository architecture, mode split, networking summary, configuration model
- [`CLI_BEHAVIOR.md`](CLI_BEHAVIOR.md) — CLI behavior contract

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
