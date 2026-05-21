# mpd — Moodle plugin development environment

`mpd` is a Moodle plugin development environment that runs every dev
tool — PHP, Composer, Node, even AI coding agents — inside an
isolated runtime container. Your laptop stays untouched. You SSH into
the runtime from your terminal or IDE (PHPStorm Gateway, VSCode
Remote-SSH) and find PHP, Composer, Node, and your AI agent (Claude Code,
Codex, Cursor, Aider) waiting for you there. Project dependencies
and the AI itself stay confined to the runtime.

Three modes, distinguished by where you sit and where `mpd` runs:

- **Sandbox VM** — full GNOME desktop inside the VM. GNOME terminal
  runs `mpd`, GNOME Firefox visits `mpd.test`, GNOME-launched VS Code
  Remote-SSH'es one hop into the local runtime container — no
  host↔VM hop because GNOME *is* the VM. Lowest friction; safest for
  AI-driven workloads. One command (`demo moodle v5.2.0`) gets you a
  fully-installed Moodle site for kicking the tires. Recommended
  starting point.
- **`mpd-machine`** — automated headless VM. You stay on your host
  (macOS / Ubuntu / Windows): your host browser visits `*.mpd.test`
  directly (via the route + DNS the bootstrap configured); your host
  terminal SSH'es into the VM to run the `mpd` CLI; your IDE
  (PHPStorm Gateway / VSCode Remote-SSH) SSH'es one hop further
  into the runtime container inside the VM.
- **`mpd-desktop`** — `mpd` is a native macOS binary you run in your
  local Terminal — no SSH hop to a VM. macOS browser sees `*.mpd.test`
  via a local WireGuard tunnel; Podman Desktop manages the Linux
  container machine in the background; your IDE SSH'es straight
  into the runtime container.

Same CLI surface, same `*.mpd.test` URLs, same per-project
configuration model. Switch between modes without relearning.

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
- **VS Code Remote-SSH / PHPStorm Gateway connect straight into the
  runtime** — IDE on your host, language server / Xdebug / phpunit /
  composer running inside the isolated container. The portal at
  `https://mpd.test/` shows a one-click `vscode://` link per project
  plus the SSH details to paste into Gateway. The Sandbox VM also
  ships VS Code pre-installed in its GNOME desktop. AI agents land
  in the same runtime.
- **Sandbox VM** (`mpd-machine`) — snapshottable and disposable;
  revert to a known-good snapshot or rebuild from scratch when needed.

## Three modes

|                      | **Sandbox VM**                                                                           | **`mpd-machine`**                                                   | **`mpd-desktop`**                                         |
|----------------------|------------------------------------------------------------------------------------------|---------------------------------------------------------------------|-----------------------------------------------------------|
| **Where `mpd` runs** | Inside the VM                                                                            | Inside a headless VM                                                | Natively on macOS                                         |
| **Where you sit**    | Inside the VM (full GNOME)                                                               | On your host (browser + SSH-into-VM)                                | On your host (Terminal + browser)                         |
| **Host OS**          | Any (UTM, Parallels, Hyper-V, VirtualBox, virt-manager, VMware…)                         | macOS, Ubuntu, Windows                                              | macOS only                                                |
| **Bootstrap**        | Install Debian Trixie + GNOME, snapshot, run one script in the VM                        | `setup.command` / `setup.sh` / `setup.cmd`                          | Install Podman Desktop + WireGuard, `mpd --setup`         |
| **Network**          | Internal to the VM (host untouched)                                                      | Plain L3 route + DNS resolver on host                               | gvproxy + WireGuard tunnel                                |
| **Best for**         | Newcomers; AI-safety; host stays untouched; hypervisor snapshot/revert as the safety net | Native host integration — laptop browser sees `*.mpd.test` directly | Already on Podman Desktop; minimal explicit VM management |

Same CLI surface, same `*.mpd.test` URLs, same per-project configuration
model.

## Get started

### 1. Sandbox VM (recommended for newcomers)

Works in any hypervisor (UTM, Parallels, Hyper-V, VirtualBox,
virt-manager, VMware…):

1. Install Debian Trixie (13) with the GNOME desktop in your
   hypervisor of choice. When the installer asks for a hostname,
   type **`mpd-machine-sandbox`**.
2. Take a hypervisor snapshot.
3. Inside the VM, run (uses `wget` — `curl` isn't in Debian's default
   install):

       bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/setup/sandbox/take-over-sandbox-vm.sh)

Open Firefox-ESR inside the VM and browse to https://mpd.test/.

### 2. `mpd-machine` (host reaches into a Linux VM)

Pick this when you want your laptop's own browser/IDE to resolve
`*.mpd.test` directly — host gets a static route + DNS resolver +
CA trust automatically. Matched-host bootstrap per OS:

| Host                 | Bootstrap                                    |
|----------------------|----------------------------------------------|
| macOS (UTM)          | [setup/macos-utm/README.md](setup/macos-utm/README.md)             |
| Ubuntu (libvirt/KVM) | [setup/ubuntu-kvm/README.md](setup/ubuntu-kvm/README.md)            |
| Windows (Hyper-V)    | [setup/windows-hyperv/README.txt](setup/windows-hyperv/README.txt)       |

### 3. `mpd-desktop` (native Podman Desktop on macOS)

For macOS users already invested in Podman Desktop, or who'd rather
not manage a hypervisor explicitly: see
[docs/desktop/USAGE.md](docs/desktop/USAGE.md).

## Prerequisites at a glance

**Sandbox VM**
- Any hypervisor that boots Debian Trixie with the GNOME desktop. Set
  the hostname to `mpd-machine-sandbox` during install and take a
  snapshot before running the take-over script.

**`mpd-machine`**
- A matched host: macOS+UTM, Ubuntu+KVM, or Windows+Hyper-V.
- The platform's setup script (`setup.command` / `setup.sh` /
  `setup.cmd`) does VM creation + cloud-init + repo clone + build +
  host-side networking (route, DNS resolver, CA trust) in one shot.
- Host changes are scoped (a route to the container subnet, a DNS
  resolver drop-in for `*.mpd.test`, mpd's local CA in the trust
  store) and reversible via the matching `uninstall` script —
  designed to coexist with normal daily-driver use. The Debian
  Trixie VM is the part dedicated to mpd; wipe-and-rebuild lives
  there.

**`mpd-desktop`**
- macOS on Apple Silicon
- [Podman Desktop](https://podman-desktop.io/) with a rootful machine
- [WireGuard for macOS](https://apps.apple.com/app/wireguard/id1451685025)
- Xcode command-line tools (for building `bin/mpd`)

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
anything else), and the Sandbox VM mode as the recommended starting
point — a whole hypervisor between your dev work and your host, with
snapshot/revert as the safety net for letting an agent rip without
thinking. Full rationale in [docs/VISION.md](docs/VISION.md).

## License

Copyright (C) 2026 Petr Skoda. [GPL-3.0](LICENSE) or later.

mpd is my first fully AI-driven project. Built with
[Claude Code](https://claude.ai/code) (Anthropic) and [Codex](https://openai.com/codex/) (OpenAI).
It's open source so other Moodle developers can experience
this kind of workflow too.

Moodle is a registered trademark of [Moodle Pty Ltd](https://moodle.com).
