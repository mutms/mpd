# mpd — Moodle plugin development environment

`mpd` is a Moodle plugin development environment that runs every dev
tool — PHP, Composer, Node, even AI coding agents — inside an
isolated runtime container. Your laptop stays untouched. You SSH into
the runtime from your terminal or IDE (PHPStorm Gateway, VSCode
Remote-SSH) and find PHP, Composer, and your AI agent (Claude Code,
Codex, Cursor, Aider) waiting for you there. Project dependencies
and the AI itself stay confined to the runtime.

Two modes: native macOS (`mpd-desktop`) or a Linux sandbox VM
(`mpd-machine`). Same workflow either way; run both side-by-side,
switch without relearning.

## What you get

- **`https://<project>.mpd.test/` for every project** — real cert
  (signed by a name-constrained local CA), no warnings, no `--insecure`,
  works the moment `mpd start <project>` returns.
- **Mailpit for outbound mail** — visit `https://mail.<project>.mpd.test/`
  and you land on the runtime's shared mailpit UI with the project's
  mail pre-filtered. Activation links, password resets, notifications —
  all caught, nothing leaves the pod.
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
- **Sandbox VM** (`mpd-machine`) — let an agent do anything; if you
  don't like the result, throw the VM away and start over.

## Two modes

| | `mpd-desktop` | `mpd-machine` |
|---|---|---|
| **Host OS** | macOS only | macOS, Linux, Windows, or cloud |
| **Backend** | Podman Desktop + WireGuard tunnel | Rootful Podman in a sandbox VM |
| **Best for** | Native macOS workflows; simplest setup on a Mac | Non-macOS hosts; sandbox you can wipe and rebuild; letting an AI agent run wild |
| **Network model** | gvproxy + WireGuard | Plain L3 routing from laptop to VM |

Same CLI surface, same `*.mpd.test` URLs, same per-project configuration
model.

## Get started

| Path | Doc |
|---|---|
| `mpd-desktop` (macOS native) | [docs/desktop/USAGE.md](docs/desktop/USAGE.md) |
| `mpd-machine` — automated UTM bootstrap on macOS | [mpd-machine/platforms/macos-utm/README.md](mpd-machine/platforms/macos-utm/README.md) |
| `mpd-machine` — manual bootstrap on any Debian Trixie VM | [mpd-machine/platforms/generic-vm/README.md](mpd-machine/platforms/generic-vm/README.md) |
| `mpd-machine` — Windows + Hyper-V | manual today via the `generic-vm/` path; automated PowerShell bootstrap [in development](docs/ROADMAP.md) |

## Prerequisites at a glance

**`mpd-desktop`**
- macOS on Apple Silicon
- [Podman Desktop](https://podman-desktop.io/) with a rootful machine
- [WireGuard for macOS](https://apps.apple.com/app/wireguard/id1451685025)
- Xcode command-line tools (for building `bin/mpd`)

**`mpd-machine`**
- A Debian Trixie VM — official Debian cloud image with cloud-init
  (the macOS + UTM automation does this for you), or a manual install
  from the netinst ISO (`debian-13.4.0-arm64-netinst.iso` on arm64 /
  Apple Silicon hosts, `debian-13.4.0-amd64-netinst.iso` on amd64 /
  Intel / AMD hosts).
- Don't run `mpd-machine` on a Linux box you care about. mpd makes
  invasive changes (apt installs, systemd config, passwordless sudo);
  use a sandbox VM you're willing to wipe.

## Repository layout

- `bin/` — local built binaries (`bin/mpd`)
- `conf/` — persistent local trust/network material (CA, service certs,
  WireGuard keys on mpd-desktop, `platform.env`)
- `mpd/` — Swift control-plane sources
- `assets/` — runtime/service/sidecar definitions and shell scripts
- `mpd-machine/` — VM bootstrap scripts and platform-specific assets
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

- Automated **Windows + Hyper-V** bootstrap (`platforms/windows-hyperv/`).
- Public preview URLs via **Cloudflare Tunnel + Cloudflare Access** —
  for sharing a project with a teammate, client, or an iPad-armed
  friend doing vibe-coding from across the country. Exposed as a
  `publish` tool inside the runtime, invoked over SSH.
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
