# mpd-desktop

`mpd-desktop` runs the full mpd container stack natively on macOS via
**Podman Desktop**, with a local **WireGuard tunnel** as the bootstrap
that lets your Mac reach the container subnet directly. Everything lives
inside Podman; nothing dev-related lands on the host.

For the full pitch (why containers-only, why SSH-everywhere, why the
local CA is name-constrained), see [../VISION.md](../VISION.md). This
page is the "what is it, when do I pick it, what do I need" reference.

## When to pick mpd-desktop

Pick this mode if you want:

- **Direct IP access to every container from macOS** — once the
  WireGuard tunnel is up, every project URL
  (`https://<project>.mpd.test/`), every runtime SSH
  (`ssh user@php.runtime.mpd.test`), every database is reachable
  directly from the Mac.
- **No hypervisor to drive yourself** — Podman Desktop manages its
  Linux machine for you. You don't pick a hypervisor, you don't
  snapshot, you don't power-cycle a VM. The machine spins up when
  containers run.
- **Existing Podman Desktop investment** — if you're already using
  Podman Desktop for other container work on macOS, mpd fits into
  that workflow.

Note that project source code, the AI agent's working directory, and
all generated state still live inside Podman Desktop's Linux machine
(at `/srv/projects/...`), not on the macOS filesystem — same shape as
mpd-machine. macOS Finder / Time Machine / Spotlight do not see
project files; only the mpd source checkout (`~/Developer/mpd/`) is
on the host.

Prefer [`mpd-machine`](../machine/README.md) on macOS if you'd rather
drive the VM yourself (UTM) for explicit lifecycle control, or want
a snapshottable VM. Prefer
[Sandbox VM](../../setup/sandbox/README.md) if you want the strongest
isolation and don't need anything on the host configured.

## Prerequisites

- **macOS on Apple Silicon** — Intel Macs are not supported.
- **[Podman Desktop](https://podman-desktop.io/)** — the rootful
  Podman-machine VM is what the rest of mpd runs inside. Create and
  start the machine in Podman Desktop's UI before running `mpd --setup`.
  Name it `mpd-desktop` (or `mpd-desktop-<suffix>` for concurrent
  variants — lowercase alphanumeric suffix). mpd does not create
  machines for you; it adopts whichever matching machine you have
  running.
- **[WireGuard for macOS](https://apps.apple.com/app/wireguard/id1451685025)**
  — the laptop-side end of the WireGuard tunnel. mpd generates the
  config at setup time; you import it into the WireGuard app once and
  enable On-Demand for auto-reconnect.
- **Xcode command-line tools** — `xcode-select --install`. Required to
  build `bin/mpd`.

## Bootstrap and setup

Three phases: install the prerequisites above, build the binary, run
`mpd --setup`. Detailed walkthrough in [USAGE.md](USAGE.md):

1. `git clone https://github.com/mutms/mpd.git ~/Developer/mpd`
2. `cd ~/Developer/mpd && make install` — builds `bin/mpd`
3. Add `~/Developer/mpd/bin` to your `PATH`
4. Create an `mpd-desktop` Podman machine in Podman Desktop (rootful)
   and start it
5. `mpd --setup` — adopts the running `mpd-desktop` machine, generates
   the local CA, sets up `/etc/resolver/mpd.test`, configures the
   Podman network and data volume, installs the always-on infra
   services, and walks you through importing the WireGuard tunnel
   config.

After that: `mpd --start` is the daily on-ramp; `mpd create <project>
+ configure + start` gets your first project running.

## What it manages

- **Runtime pods** (e.g. PHP, Node) — Podman pods with per-runtime
  sidecars (Caddy frontdoor for TLS, plus Mailpit / Selenium / Valkey
  attached on demand).
- **Project lifecycle** — `create` / `configure` / `start` / `stop` /
  `delete`, with project-type-specific scripts under `assets/runtimes/`.
- **Always-on infra services** — WireGuard gateway, dnsmasq, portal,
  Adminer, fileaccess (the SSH/scp endpoint backed by the data volume).
- **Local DNS and HTTPS** — `*.mpd.test` resolves via dnsmasq, project
  URLs are signed by the local CA, automatic per-project routing through
  the runtime's Caddy frontdoor.

For the under-the-hood detail, see [../ARCHITECTURE.md](../ARCHITECTURE.md).

## Directory model (on the Mac)

- `~/Developer/mpd/bin/` — local built binary (`bin/mpd`)
- `~/Developer/mpd/conf/` — persistent local trust/network material:
  `caroot/`, `wireguard/`, `service/`, `temp/`, `platform.env`
- `~/.mpd/` — runtime state and cache (recreated by `mpd --setup`,
  removed by `mpd --uninstall`)

Project backups live inside the data volume at `/srv/backups/` (not on
the macOS filesystem); pulled to the Mac via fileaccess SSH/scp before
wiping the Podman machine VM. See
[../ARCHITECTURE.md §10](../ARCHITECTURE.md#10-backup-persistence).

## Reference

- [USAGE.md](USAGE.md) — operational handbook (install + first project +
  day-to-day commands)
- [NETWORKING.md](NETWORKING.md) — gvproxy / WireGuard / dnsmasq design
- [SECURITY.md](SECURITY.md) — trust boundaries, intentional compromises
