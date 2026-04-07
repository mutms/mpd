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

- **Native macOS workflows** — host-side filesystem access to the
  source checkout, native Spotlight / Time Machine / Finder visibility,
  no VM layer between you and the code.
- **The simplest setup on a Mac** — Podman Desktop installs from a
  `.dmg`, WireGuard installs from the App Store, `make install` builds
  `bin/mpd`, `mpd --setup` does the rest.
- **Direct IP access to every container** — once the WireGuard tunnel
  is up, every project URL (`https://<project>.mpd.test/`), every
  runtime SSH (`ssh user@php.runtime.mpd.test`), every database is
  reachable directly from the Mac.

Prefer [`mpd-machine`](../machine/README.md) instead if you're not on
macOS, or if you want the agent to be able to wreck the dev environment
without any chance of touching your host.

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
