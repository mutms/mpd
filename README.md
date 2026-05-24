# mpd — Moodle plugin development environment

A development environment for Moodle plugin work, built so that
**every dev tool — PHP, Composer, Postgres/MariaDB, Node, even your
AI coding agent — lives inside a per-project runtime container, not
on your laptop**. You edit code in your usual IDE; the language
server, Xdebug, phpunit, composer, and the running Moodle all execute
inside the container. The result, day to day:

- **`https://<project>.mpd.test/` for every project** — browser-trusted
  HTTPS via a name-constrained local CA (signs `*.mpd.test` only),
  available the moment `mpd start <project>` returns.
- **Per-project PHP version.** `MPD_PHP_VERSION=8.4` on one project,
  `8.2` on the next, simultaneously. No system-wide `php-fpm` to
  juggle.
- **Per-project database** (Postgres / MariaDB / MySQL, version of
  your choice via `MPD_DB=postgres:18` — that's `<engine>:<version>`,
  not a port). The matching container provisions on demand; no shared
  DB server with `mdl_proj1_` / `mdl_proj2_` table prefixing.
- **Reset to clean state in one verb.** `mdl-data-purge` drops the
  DB, wipes dataroots, removes the generated config — keeps `mpd.env`
  and the source tree.
- **Mailpit per project** at `https://mail.<project>.mpd.test/` with
  this project's mail pre-filtered.
- **Behat + Selenium** auto-wired when a project asks for it
  (`https://behat.<project>.mpd.test/`).
- **No host pollution.** No Homebrew PHP, no system Apache, no
  `brew upgrade` ever broke your Moodle dev environment because of an
  unrelated OpenSSL bump.

Your IDE (VS Code Remote-SSH, PHPStorm Gateway) connects to the
runtime container over SSH — the IDE process stays on your host;
language server, debugger, and integrated terminal execute inside
the container. Your AI agent (Claude Code, Codex, Cursor, Aider) is
**installed inside the runtime** (one-line install via
`claude-install`) and runs as a process *in* the container. You
launch it from the SSH session you opened into the runtime; the
agent shares the same files, same tools, same Moodle install the
IDE is editing. SSH is a clean integration point — no filesystem-
mount layer papering over the network, no debate about where the
code "really" lives. (When the work is on **mpd itself** — Swift
sources, asset scripts — the agent runs in the VM instead, where
the source checkout and toolchain live.)

## Coming from…

- **Homebrew-native PHP + MariaDB.** mpd replaces the
  `brew install php@8.3 mariadb composer node` stack with per-project
  containers. The laptop stays clean; per-project PHP/DB versions
  work simultaneously; `brew upgrade` decisions don't touch your dev
  environment. Tradeoff: a few seconds of container startup vs
  millisecond-fast native invocation. Worth it once you've juggled
  two PHP versions on the same Mac for the third time.

- **[moodle-docker](https://github.com/moodlehq/moodle-docker).**
  mpd is shaped around the same daily-driver pattern but adds:
  per-project URLs with real HTTPS (no `localhost:8000`), per-project
  Mailpit filtering, automatic Behat/Selenium wiring, an
  SSH-into-runtime workflow that AI agents and IDEs both target, and
  a hard VM boundary on macOS so the AI agent can't touch your host.

- **[DDEV](https://ddev.com/) / [Lando](https://lando.dev/).** mpd is
  the Moodle-specific cousin: same per-project URL + auto-TLS
  philosophy, narrowed to Moodle plugin work, hardened with a VM
  boundary, and shaped around AI agents as a first-class consumer of
  the SSH-into-runtime endpoint.

## Two modes

|                      | **Sandbox VM**                                                                           | **`mpd VM`**                                                          |
|----------------------|------------------------------------------------------------------------------------------|-----------------------------------------------------------------------|
| **Where `mpd` runs** | Inside the VM                                                                            | Inside a VM (headless by default; GNOME on-demand)                    |
| **Where you sit**    | Inside the VM (full GNOME desktop)                                                       | On your host (browser + SSH-into-VM)                                  |
| **Host OS**          | Any (UTM, Parallels, Hyper-V, VirtualBox, virt-manager, VMware…)                         | macOS (primary) — Linux/Windows speculative                           |
| **Bootstrap**        | Install Debian Trixie + GNOME, snapshot, run one script in the VM                        | `mpd-virt setup` (separate orchestrator binary on the host)           |
| **Network**          | Internal to the VM (host untouched)                                                      | WireGuard tunnel host↔VM                                              |
| **Best for**         | Experiments, AI-driven workloads (the VM is the wall; snapshot/revert is the safety net) | Daily-driver Moodle work — host browser/IDE see `*.mpd.test` directly |

**Pick Sandbox if you're unsure or just want to try mpd out quickly.**
It's the fastest path to "real Moodle running locally" — one VM, one
script inside it, no host configuration. You'll be able to migrate to
standard `mpd VM` (headless, host-integrated) later without losing
projects or DBs once you know which workflow you want.

**Both modes ship GNOME.** Sandbox boots into it; mpd VM defaults to
headless to save resources, but GNOME is installed and toggleable on
demand — `gnome-start` brings the desktop up (and pins it as the
boot target until you flip back), `gnome-stop` returns to headless.
Useful when you occasionally want an in-VM Firefox session or a
GUI-based debugging tool without committing to a full graphical
boot every day.

## Get started

### 1. Sandbox VM (recommended)

**Pick a hypervisor** — free and native per OS where possible:

- **macOS (Apple Silicon)**: [UTM](https://mac.getutm.app/) — free,
  uses Apple's Virtualization.framework directly (no third-party kernel
  extensions). Or Parallels Desktop / VMware Fusion if you already
  own them.
- **Windows 11 Pro/Enterprise**: Hyper-V — built in, enable via
  "Turn Windows features on or off."
- **Linux**: virt-manager + KVM — built into most distros; `apt
  install virt-manager` on Debian/Ubuntu.
- **Anywhere else**: VirtualBox (free, cross-platform).

**Provision the VM** — Debian Trixie (13) with the GNOME desktop, 8 GB
RAM and 4 CPUs as a comfortable default (4 GB / 2 CPU minimum), 100 GB
disk. When the installer asks for a hostname, type **`mpd-sandbox`**.
Take a hypervisor snapshot after first boot — that's your safety net.

**Inside the VM**, in a terminal, run:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/setup/sandbox/take-over-sandbox-vm.sh)
```

(That syntax fetches the take-over script and runs it in one step.
`wget` because Debian's base install ships it; `curl` isn't always
present.)

Open Firefox-ESR inside the VM and browse to https://mpd.test/.

### 2. `mpd VM` (host reaches into a Linux VM)

Pick this when you want your laptop's own browser/IDE to resolve
`*.mpd.test` directly. The matched-host bootstrap configures the host
side (static route + DNS resolver + CA trust + WireGuard) so the
laptop sees the VM's container subnet:

| Host                          | Bootstrap                                                                          |
|-------------------------------|------------------------------------------------------------------------------------|
| macOS (Parallels / UTM)       | [mpd-virt-macos](https://github.com/mutms/mpd-virt-macos) — Swift CLI orchestrator |
| Ubuntu (libvirt/KVM)          | [setup/linux/README.md](setup/linux/README.md)                                     |
| Windows (Hyper-V)             | [setup/windows/README.txt](setup/windows/README.txt)                               |

The `mpd-virt-macos` repo ships a `mpd-virt` host binary that drives
Parallels Desktop Pro and UTM (via cloud-init), runs the in-VM
bootstrap pipeline over SSH, and configures the macOS side (route, DNS
resolver, CA trust, WireGuard) in one shot. Sibling `mpd-virt-linux` /
`mpd-virt-windows` repos are planned along the same shape.

## What to expect, timing-wise

- **First-time VM bootstrap**: 5–15 minutes depending on hypervisor
  speed (image download, apt installs, Swift toolchain, build).
- **First runtime build** after `mpd --setup`: 3–5 minutes (apt
  installs for PHP/Node/etc. inside the runtime container).
- **Subsequent project start** (`mpd start <project>`): a few seconds.
- **`demo moodle v5.2.0`** (one-command fully-installed Moodle): a
  few minutes the first time (runtime + DB + Moodle install in
  sequence); near-instant on re-runs (just starts the existing
  project).
- **VM resume from suspend**: seconds.

## Repository layout

- `bin/` — local built binaries (`bin/mpd`)
- `mpd/` — Swift control-plane sources (`Action/`, `VM/`, `Runtime/`, `Service/`, …)
- `assets/` — runtime/service/sidecar definitions and shell scripts
- `bootstrap/` — VM bring-up steps (passwordless sudo, repo clone, networking, apt, build, WireGuard)
- `setup/` — per-platform host orchestration (sandbox + matched-host platforms)
- `docs/` — full documentation tree
- `/var/lib/mpd/` — runtime state at runtime (created by bootstrap, populated by `mpd --setup`)

## Documentation

- [docs/README.md](docs/README.md) — documentation index, audience-shaped
- [docs/USAGE.md](docs/USAGE.md) — day-to-day handbook (project lifecycle, SSH into runtime, tools)
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — under the hood (contributor reference)
- [docs/ROADMAP.md](docs/ROADMAP.md) — what's queued next

## Why this exists

mpd grew out of a personal security stance plus a working pattern:
**I'm using AI agents (Claude Code, Codex) to build and maintain
Moodle plugins, and I want them inside a sandbox.** I'm not willing
to install Homebrew, MacPorts, Node, PHP, or Apache on my MacBook,
and I'm not willing to let an AI agent loose on it either. mpd's
predecessor ([MDC](https://github.com/skodak/mdc)) gave me speed
and automation around OrbStack, but OrbStack is closed-source — and
for a tool that decides what your browser trusts, I wanted the
trust-deciding code to be readable. mpd lives entirely in this repo:
Swift control plane plus shell tooling on top of Podman, with a
name-constrained local CA that can only sign for `*.mpd.test` (so a
compromise can't impersonate anything else). Sandbox VM is the
recommended starting point — a whole hypervisor between your dev
work and your host, with snapshot/revert as the safety net for
letting an agent rip without thinking.

## Acknowledgments

The design draws on 20 years of Moodle development, the OrbStack-era
[MDC](https://github.com/skodak/mdc) tooling, and the
[moodle-docker](https://github.com/moodlehq/moodle-docker) workflow as
the public reference everyone reaches for first. mpd is also my first
fully AI-driven project — the Swift binary, asset scripts, and
documentation are mostly written by [Claude Code](https://claude.ai/code)
(Anthropic) and [Codex](https://openai.com/codex/) (OpenAI) under my
direction. Open source so other Moodle developers can adopt the same
workflow.

## License

Copyright (C) 2026 Petr Skoda. [GPL-3.0](LICENSE) or later.

Moodle is a registered trademark of [Moodle Pty Ltd](https://moodle.com).
