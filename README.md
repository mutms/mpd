# mpd — Moodle plugin development environment

`mpd` is a Moodle plugin development environment that runs every dev
tool — PHP, Composer, Node, even AI coding agents — inside an
isolated runtime container. Your laptop stays untouched. You SSH into
the runtime from your terminal or IDE (PHPStorm Gateway, VSCode
Remote-SSH) and find PHP, Composer, Node, and your AI agent (Claude Code,
Codex, Cursor, Aider) waiting for you there. Project dependencies
and the AI itself stay confined to the runtime.

Two modes, distinguished by where you sit and where `mpd` runs:

- **Sandbox VM** — full GNOME desktop inside the VM. GNOME terminal
  runs `mpd`, GNOME Firefox visits `mpd.test`, GNOME-launched VS Code
  Remote-SSH'es one hop into the local runtime container — no
  host↔VM hop because GNOME *is* the VM. Lowest friction; safest for
  AI-driven workloads. One command (`demo moodle v5.2.0`) gets you a
  fully-installed Moodle site for kicking the tires. Recommended
  starting point.
- **`mpd-machine`** — automated headless VM driven from your host
  via the companion `mpd-virt` orchestrator (Parallels Desktop Pro on
  macOS is the primary target; KVM/Hyper-V are speculative). Your
  host browser visits `*.mpd.test` directly over WireGuard; your
  host terminal SSH'es into the VM to run the `mpd` CLI; your IDE
  (PHPStorm Gateway / VSCode Remote-SSH) SSH'es one hop further
  into the runtime container inside the VM.

Same CLI surface, same `*.mpd.test` URLs, same per-project
configuration model.

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

## Two modes

|                      | **Sandbox VM**                                                                           | **`mpd-machine`**                                                   |
|----------------------|------------------------------------------------------------------------------------------|---------------------------------------------------------------------|
| **Where `mpd` runs** | Inside the VM                                                                            | Inside a headless VM                                                |
| **Where you sit**    | Inside the VM (full GNOME)                                                               | On your host (browser + SSH-into-VM)                                |
| **Host OS**          | Any (UTM, Parallels, Hyper-V, VirtualBox, virt-manager, VMware…)                         | macOS (primary) — Linux/Windows speculative                         |
| **Bootstrap**        | Install Debian Trixie + GNOME, snapshot, run one script in the VM                        | `mpd-virt setup` (separate orchestrator binary on the host)         |
| **Network**          | Internal to the VM (host untouched)                                                      | WireGuard tunnel host↔VM                                            |
| **Best for**         | Experiments + Linux testing; throwaway VM with snapshot/revert as the safety net         | Daily-driver work — host browser/IDE see `*.mpd.test` directly      |

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

| Host                          | Bootstrap                                                          |
|-------------------------------|--------------------------------------------------------------------|
| macOS (Parallels Desktop Pro) | [setup/macos/README.md](setup/macos/README.md)             |
| Ubuntu (libvirt/KVM)          | [setup/linux/README.md](setup/linux/README.md)           |
| Windows (Hyper-V)             | [setup/windows/README.txt](setup/windows/README.txt) |

## Prerequisites at a glance

**Sandbox VM**
- Any hypervisor that boots Debian Trixie with the GNOME desktop. Set
  the hostname to `mpd-machine-sandbox` during install and take a
  snapshot before running the take-over script.

**`mpd-machine`**
- A matched host: macOS + Parallels Desktop Pro (primary) — Linux/KVM
  and Windows/Hyper-V are speculative future targets.
- The `mpd-virt` orchestrator binary on the host (separate repository)
  does VM creation + cloud-init + repo clone + build + host-side
  networking (WireGuard, CA trust) in one shot.
- Host changes are scoped (WireGuard tunnel to the container subnet,
  mpd's local CA in the trust store) and reversible via
  `mpd-virt uninstall`.

## Repository layout

- `bin/` — local built binaries (`bin/mpd`)
- `mpd/` — Swift control-plane sources
- `assets/` — runtime/service/sidecar definitions and shell scripts
- `setup/` — bootstrap scripts (sandbox + matched-host platforms)
- `docs/` — full documentation tree
- `~/.mpd/` — runtime state and cache (recreated by `mpd --setup`)

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
