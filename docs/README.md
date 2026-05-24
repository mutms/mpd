# mpd documentation

Index for the `docs/` tree. The user-facing pitch + mode picker
lives in [`../README.md`](../README.md) — start there if you
haven't already.

## If you're installing or using mpd

In rough order of when you'll want them:

- [`../README.md`](../README.md) — pitch + "Two modes" picker + first
  bootstrap. The single starting point.
- The bootstrap doc for your chosen mode (linked from the top-level
  README's "Get started" section):
  - [`../setup/sandbox/README.md`](../setup/sandbox/README.md) — Sandbox VM (any hypervisor)
  - [`mpd-virt-macos`](https://github.com/mutms/mpd-virt-macos) (separate repo) — mpd VM on macOS via Parallels / UTM
  - [`../setup/linux/README.md`](../setup/linux/README.md) — mpd VM on Ubuntu via libvirt/KVM
  - [`../setup/windows/README.txt`](../setup/windows/README.txt) — mpd VM on Windows via Hyper-V
- [`USAGE.md`](USAGE.md) — universal day-to-day handbook. Project
  lifecycle, SSH into the runtime, tools list, git auth via agent
  forwarding, project backups. Applies to both modes once setup
  has completed.
- [`NETWORKING.md`](NETWORKING.md) — host ↔ VM ↔ container routing
  model for laptop-driven setups (WireGuard tunnel, DNS split,
  ProxyJump SSH config). Read when reachability isn't working or
  you're curious about the path packets take.
- [`SECURITY.md`](SECURITY.md) — trust boundaries, threat model,
  what mpd is and isn't designed to protect. Read when you're
  deciding whether to let an AI agent loose, or when something
  feels too privileged.

## If you're working on mpd itself

Or you're an AI agent helping out:

- [`../AGENTS.md`](../AGENTS.md) — agent + contributor starting
  point. Fixed paths, code layout, mandatory privilege and
  architecture rules, verb/tool authoring contract. Read first.
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — repo architecture, mode
  split, networking summary, configuration model, verb/tool
  contract in depth. The "under the hood" reference.
- [`CLI_BEHAVIOR.md`](CLI_BEHAVIOR.md) — **behavioral contract** for
  CLI changes. Spec, not a manual: if implementation diverges,
  align code to this doc or update the doc in the same change.
- [`HOOKS.md`](HOOKS.md) — typed `Event` lifecycle hooks: events,
  audiences, asset-side `hooks/<event>.d/` scripts. Read when
  adding a hook trigger or authoring a hook script.
- [`proposals/`](proposals/) — design docs for parked exploratory
  ideas (e.g. the nested-Podman deployment mode). Each proposal
  is precise enough that a contributor can implement it without
  re-deriving the design.

## Direction

- [`ROADMAP.md`](ROADMAP.md) — queued work + parked ideas.

## Shared in-VM directory model

Quick reference; full contract in [`ARCHITECTURE.md`](ARCHITECTURE.md).

- `/opt/mpd/` — code, assets, built binary (`/opt/mpd/bin/mpd`).
  Owned by the dev user.
- `/var/lib/mpd/conf/` — persistent identity: CA, service certs,
  `platform.env`, WireGuard private key. PRIVATE — never bind-mounted
  into containers.
- `/var/lib/mpd/env/mpd-vm.env` — user-editable VM-wide env
  overrides. Bind-mounted RO into every runtime container.
- `/var/lib/mpd/skel/` — optional user-managed dotfile defaults for
  new runtimes (`/etc/skel/`-style). Empty by default.
- `/var/lib/mpd/state/` — mpd-managed operational state
  (projects.json, runtimes/, dnsmasq.d/, etc.). Wipe to reset.
- `/srv/` — Podman data volume, only exists inside containers
  (projects/, data/, meta/, dbs/, tools/, backups/).

Project backups live in `/srv/backups/` inside the data volume and
are pulled off via fileaccess SSH/scp before wiping. Full contract:
[`ARCHITECTURE.md` §10](ARCHITECTURE.md#10-backup-persistence).
