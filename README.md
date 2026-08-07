# mpd — Moodle plugin development environment

The environment I use for my own daily Moodle work. Every dev tool — PHP,
Composer, Postgres/MariaDB, Node, even the AI coding agent — lives in
containers inside a Linux VM, not on your laptop. Each project gets its
own `https://<project>.<NNN>.mpd.test/` URL with browser-trusted TLS, its
own PHP version and database, and automatic Behat/Selenium wiring; Mailpit
and Adminer are one command away. You edit in your usual IDE over SSH; the
host stays clean, and everything an agent can touch is disposable.

The details — design, motivation, comparisons with moodle-docker/DDEV, the
IDE and agent workflow — live in [AGENTS.md](AGENTS.md) and
[docs/](docs/README.md). They are written so you can also just point an AI
assistant at this repo and ask.

## The mpd family

| Repo                                            | Runs                    | Does                                                                     |
|-------------------------------------------------|-------------------------|--------------------------------------------------------------------------|
| **mpd** (this repo)                             | inside the VM           | the runtime, projects, DNS, TLS — the control plane                      |
| [mpd-virt](https://github.com/mutms/mpd-virt)   | on the Mac              | creates/adopts VMs, host reachability + CA trust                         |
| [mpd-proxy](https://github.com/mutms/mpd-proxy) | on the Mac, as root     | optional: transparent `*.mpd.test` for every app via a WireGuard overlay |
| [mudev](https://github.com/mutms/mudev)         | on the VM + in runtimes | assembles Moodle trees from recipes; the plugin/recipe catalogues        |

## Try it: Sandbox VM

One VM, one script, no host configuration — and you can adopt it as a
managed VM later without losing projects.

Install **Debian Trixie (13) with GNOME** in any hypervisor (UTM, Parallels,
VMware, Hyper-V, virt-manager/KVM, VirtualBox…): 8 GB RAM / 4 CPUs
comfortable, 100 GB disk. When the installer asks for a hostname, type
**`mpd-<NNN>`** — a 3-digit id in 100..254, e.g. `mpd-137`; everything
(zone, subnet, name) derives from it. Snapshot after first boot, then run in
a terminal inside the VM:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/setup/mpd-sandbox-setup.sh)
```

It converts the network stack (one reboot), installs mpd, and generates the
CA. Then, for your first Moodle:

```bash
mpd --vm-setup                       # idempotent; no-op if the setup script ran it
demo moodle/release/4.5.12 demo45    # fully installed Moodle in one command
```

`demo` prints the URL and admin credentials — open it in the VM's Firefox,
and `ssh mpd-<NNN>-runtime` for a shell inside the runtime serving it. Recipes
come from [mudev](https://github.com/mutms/mudev); `demo` with no arguments
lists what's available. `mpd --vm-upgrade` updates mpd in place later.

## Daily driver: mpd VM

Same VM, headless, with your laptop's own browser and IDE resolving
`*.mpd.test` directly. On macOS, [mpd-virt](https://github.com/mutms/mpd-virt)
creates or adopts the VM and wires the host side in one shot; on Linux and
Windows the in-repo automation is [setup/linux/](setup/linux/README.md) and
[setup/windows/](setup/windows/README.txt) (less exercised). A sandbox is
adopted with `mpd-virt takeover <NNN> --backend=<backend>` (the box is
found over mDNS; pass the IP if that can't reach it) — projects survive.

## Documentation

- [docs/README.md](docs/README.md) — index, audience-shaped
- [docs/USAGE.md](docs/USAGE.md) — day-to-day handbook (projects, SSH into
  the runtime, tools, updating)
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — under the hood
- [AGENTS.md](AGENTS.md) — background, layout, and conventions, for AI
  agents and humans alike

## About

I built these tools for my own daily Moodle work — shaped by 20 years of
Moodle development, standing on my OrbStack-era
[MDC](https://github.com/skodak/mdc) and on
[moodle-docker](https://github.com/moodlehq/moodle-docker) — and I release
them because I like open source. Try them, break them, send issues or PRs.

mpd and its related tools are my first fully AI-driven project — the Go, the
asset scripts, and the docs are largely written by
[Claude Code](https://claude.com/claude-code) (Anthropic) under my direction
(design and review stay human).

## License

Copyright (C) 2026 Petr Skoda. [GPL-3.0](LICENSE) or later.

Moodle is a registered trademark of [Moodle Pty Ltd](https://moodle.com).
