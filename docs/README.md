# mpd documentation

Index for the `docs/` tree. The top-level [`../README.md`](../README.md) is
deliberately terse — what mpd is and the sandbox quickstart; the background
(motivation, comparisons, workflow shape) lives in
[`../AGENTS.md`](../AGENTS.md).

## If you're installing or using mpd

In rough order of when you'll want them:

- [`../README.md`](../README.md) — overview + sandbox quickstart. The
  starting point.
- The bootstrap doc for your chosen mode:
  - [`../setup/mpd-sandbox-setup.sh`](../setup/mpd-sandbox-setup.sh) — Sandbox VM (any
    hypervisor; run via the wget one-liner in the top-level README)
  - [`mpd-virt`](https://github.com/mutms/mpd-virt) (separate repo) — mpd VM from a macOS host (Parallels / UTM / Apple container) or a Linux host (libvirt/KVM), plus Proxmox and any reachable Debian VM
- [`usage.md`](usage.md) — universal day-to-day handbook. Project
  lifecycle, extra services, SSH into the runtime, tools list, git auth
  via agent forwarding, backups. Applies to both modes once setup
  has completed.
- [`networking.md`](networking.md) — host ↔ VM ↔ container reachability
  model: the WireGuard overlay (mpd-proxy) or the SOCKS-over-SSH fallback,
  split DNS, the container-subnet firewall, ProxyJump SSH config. Read when
  reachability isn't working or you're curious about the path packets take.
- [`security.md`](security.md) — trust boundaries, threat model,
  what mpd is and isn't designed to protect. Read when you're
  deciding whether to let an AI agent loose, or when something
  feels too privileged.
- [`debugging.md`](debugging.md) — catalogue of real symptoms with
  the diagnostic that confirms each and the fix. Read when the runtime
  or IDE session misbehaves (lockups, thread/fork exhaustion, …).

## If you're working on mpd itself

Or you're an AI agent helping out:

- [`../AGENTS.md`](../AGENTS.md) — agent + contributor starting
  point. Fixed paths, code layout, mandatory privilege and
  architecture rules, verb/tool authoring contract. Read first.
- [`architecture.md`](architecture.md) — repo architecture, mode
  split, networking summary, configuration model, verb/tool
  contract in depth. The "under the hood" reference.
- [`cli-behavior.md`](cli-behavior.md) — behavioral reference for
  CLI changes, kept in sync with the implementation: update it in
  the same change that alters CLI behavior.
- [`hooks.md`](hooks.md) — typed `Event` lifecycle hooks: events,
  audiences, asset-side `hooks/<event>.d/` scripts. Read when
  adding a hook trigger or authoring a hook script.

## Shared in-VM directory model

Quick reference; full contract in [`architecture.md`](architecture.md).

- `/opt/mpd/` — code, assets, built binary (`/opt/mpd/bin/mpd`).
  Owned by the dev user.
- `/var/lib/mpd/conf/` — persistent identity: CA, service certs. PRIVATE — never bind-mounted
  into containers.
- `/var/lib/mpd/env/{vm.env,runtime.env}` — the developer's own env,
  shared across their VMs (pushed in from the Mac by mpd-virt). `runtime.env`
  is bind-mounted RO into every runtime container; `vm.env` is sourced into
  the VM's own shells only.
- `/var/lib/mpd/skel/` — optional user-managed dotfile defaults for
  the runtime container (`/etc/skel/`-style). Empty by default.
- `/var/lib/mpd/state/` — mpd-managed operational state
  (projects.json, services.json, runtimes/ — the single runtime's
  entry — etc.). Wipe to reset. DNS records live in the VM's
  `/etc/hosts`, in a block mpd rewrites from this state.
- `/srv/` — Podman data volume, mounted on the VM and in every
  container at the same path (projects/, data/, meta/, dbs/, extra/,
  backups/).

Backups live in `/srv/backups/` on the data volume (`mpd
--runtime-backup` writes `backups/runtime/<timestamp>/`) and are
expected to be copied off the VM manually with scp before wiping.
Full contract: [`architecture.md` §10](architecture.md#10-backup-persistence).
