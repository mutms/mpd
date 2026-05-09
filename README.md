# mpd — Moodle plugin development environment

`mpd` is a Moodle plugin development environment that runs every dev
tool — PHP, Composer, Node, even AI coding agents — inside an
isolated runtime container. Your laptop stays untouched. You SSH into
the runtime from your terminal or IDE (PHPStorm Gateway, VSCode
Remote-SSH) and find PHP, Composer, and your AI agent (Claude Code,
Codex, Cursor, Aider) waiting for you there. Project dependencies
and the AI itself stay confined to the runtime.

Two modes: native macOS (`mpd-desktop`) or a Linux sandbox VM
(`mpd-machine`). `mpd-machine` runs on macOS, Linux, and Windows —
Windows users get a fully automated setup via `setup.cmd` (Hyper-V,
no WSL, no manual networking). Same workflow either way; same
`*.mpd.test` URLs, same CLI, switch without relearning.

## What you get

- **`https://<project>.mpd.test/` for every project** — browser-trusted
  HTTPS via a name-constrained local CA; available as soon as
  `mpd start <project>` returns.
- **Mailpit for outbound mail** — mail sent from the project is captured
  by Mailpit at `https://mail.<project>.mpd.test/`, pre-filtered per
  project. Mail does not leave the runtime.
- **Postgres / MariaDB / MySQL** — pick a version with
  `MPD_DB=postgres:18`; the matching container provisions on demand.
  Adminer is always running at `https://adminer.service.mpd.test/`
  for browsing every project's DB.
- **Behat + Selenium** wired automatically when a project asks for it
  (`https://behat.<project>.mpd.test/`).
- **PHPStorm Gateway / VSCode Remote-SSH connect straight into the
  runtime** — IDE on your host, language server / Xdebug / phpunit /
  composer running inside the isolated container. AI agents land in
  the same place.
- **Sandbox VM** (`mpd-machine`) — disposable; rebuild from scratch when
  needed.

## Two modes

| | `mpd-desktop` | `mpd-machine` |
|---|---|---|
| **Host OS** | macOS only | macOS, Linux, Windows, or cloud |
| **Backend** | Podman Desktop + WireGuard tunnel | Rootful Podman in a sandbox VM |
| **Best for** | Native macOS workflows; simplest setup on a Mac | Non-macOS hosts; sandbox you can wipe and rebuild; untrusted or AI-driven workloads |
| **Network model** | gvproxy + WireGuard | Plain L3 routing from laptop to VM |

Same CLI surface, same `*.mpd.test` URLs, same per-project configuration
model.

## Get started

**New here?** Try the sandbox first — works in any hypervisor (UTM,
Hyper-V, VirtualBox, virt-manager, VMware…):

1. Install Ubuntu 26.04 LTS desktop in your hypervisor of choice.
   During the installer, set the hostname to **`mpd-machine-sandbox`**.
2. Take a hypervisor snapshot.
3. Inside the VM, run:

       bash <(curl -sSL https://raw.githubusercontent.com/mutms/mpd/main/setup/sandbox/take-over-sandbox-vm.sh)

Open Firefox inside the VM and browse to https://mpd.test/.

**Want host integration?** (route + DNS + CA trust on your host so you
can browse `*.mpd.test` from your laptop's own browser, not just from
inside a VM window.) Pick the matched-host bootstrap for your OS:

| Path | Doc |
|---|---|
| `mpd-desktop` (macOS native, no VM at all) | [docs/desktop/USAGE.md](docs/desktop/USAGE.md) |
| `mpd-machine` on macOS (UTM) | [setup/macos-utm/README.md](setup/macos-utm/README.md) |
| `mpd-machine` on Ubuntu (libvirt/KVM) | [setup/ubuntu-kvm/README.md](setup/ubuntu-kvm/README.md) |
| `mpd-machine` on Windows (Hyper-V) | [setup/windows-hyperv/README.txt](setup/windows-hyperv/README.txt) |

## Prerequisites at a glance

**`mpd-desktop`**
- macOS on Apple Silicon
- [Podman Desktop](https://podman-desktop.io/) with a rootful machine
- [WireGuard for macOS](https://apps.apple.com/app/wireguard/id1451685025)
- Xcode command-line tools (for building `bin/mpd`)

**`mpd-machine` — sandbox**
- Any hypervisor + an Ubuntu 26.04 LTS desktop install with hostname
  `mpd-machine-sandbox`. Snapshot before running the take-over script.

**`mpd-machine` — host-integrated platforms**
- `setup.command` (macOS+UTM), `setup.sh` (Ubuntu+KVM), `setup.cmd`
  (Windows+Hyper-V) each do VM creation + cloud-init + repo clone +
  build + host-side networking (route, DNS resolver, CA trust) in
  one shot.
- Don't run `mpd-machine` on a Linux box you care about. mpd makes
  invasive changes (apt installs, systemd config, passwordless sudo);
  use a sandbox VM you're willing to wipe.

## Repository layout

- `bin/` — local built binaries (`bin/mpd`)
- `conf/` — persistent local trust/network material (CA, service certs,
  WireGuard keys on mpd-desktop, `platform.env`)
- `mpd/` — Swift control-plane sources
- `assets/` — runtime/service/sidecar definitions and shell scripts
- `setup/` — bootstrap scripts (sandbox + matched-host platforms)
- `docs/` — full documentation tree
- `~/.mpd/` — runtime state and cache (recreated by `mpd --setup`,
  removed by `mpd --uninstall`)

## Documentation

- [docs/README.md](docs/README.md) — full documentation index
- [docs/VISION.md](docs/VISION.md) — *Why mpd* — origin story, design
  principles, the AI-friendly SSH inversion, what mpd feels like to use
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — under the hood
- [docs/CLI_BEHAVIOR.md](docs/CLI_BEHAVIOR.md) — CLI behavior contract
- [docs/ROADMAP.md](docs/ROADMAP.md) — what's queued next

## Roadmap (short form)

- Public preview URLs via **Cloudflare Tunnel + Cloudflare Access** —
  share a project URL with a teammate, client, or external collaborator.
  Exposed as a `publish` tool inside the runtime, invoked over SSH.
- `mdl-backup` / `mdl-restore` — Moodle-only tools that produce /
  consume one tar bundle per project (dataroot + DB dump).

Detail and rationale in [docs/ROADMAP.md](docs/ROADMAP.md).

## Why this exists

mpd grew out of a personal security stance: I'm not willing to install
Homebrew, MacPorts, Node, PHP, or Apache on my MacBook — and I'm not
willing to let an AI coding agent loose on it either. mpd's predecessor
([MDC](https://github.com/skodak/mdc)) gave me speed and automation
around OrbStack; mpd moves the work behind firmer walls: containers
always (dev tools and AI agents alike), a name-constrained local CA
that can only sign for `*.mpd.test` (so a compromise can't impersonate
anything else), and an optional sandbox-VM mode that adds a second
wall around everything for the times I want to let an agent rip
without thinking. Full rationale in [docs/VISION.md](docs/VISION.md).

## License

Copyright (C) 2026 Petr Skoda. [GPL-3.0](LICENSE) or later.

mpd is my first fully AI-driven project. Built with
[Claude Code](https://claude.ai/code) (Anthropic) and [Codex](https://openai.com/codex/) (OpenAI).
It's open source so other Moodle developers can experience
this kind of workflow too.

Moodle is a registered trademark of [Moodle Pty Ltd](https://moodle.com).
