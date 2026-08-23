# mpd — Moodle plugin development environment

The environment I use for my own daily Moodle work. Every dev tool — PHP,
Composer, Postgres/MariaDB, Node, the AI coding agent — lives in a container
inside a Linux VM, not on your laptop. Each project gets its own
`https://<project>.<NNN>.mpd.test/` URL with trusted TLS, its own PHP
version and database, and Behat/Selenium wiring. You edit in your IDE over
SSH; the host stays clean.

Design, motivation and comparisons with moodle-docker/DDEV are in
[AGENTS.md](AGENTS.md) and [docs/](docs/README.md) — or point an AI
assistant at this repo and ask.

## The mpd family

| Repo                                            | Runs                    | Does                                                                     |
|-------------------------------------------------|-------------------------|--------------------------------------------------------------------------|
| **mpd** (this repo)                             | inside the VM           | the runtime, projects, DNS, TLS — the control plane                      |
| [mpd-virt](https://github.com/mutms/mpd-virt)   | on the host             | creates/adopts VMs, host reachability + CA trust                         |
| [mpd-proxy](https://github.com/mutms/mpd-proxy) | on the host, as root    | optional: transparent `*.mpd.test` for every app via a WireGuard overlay |
| [mudev](https://github.com/mutms/mudev)         | on the VM + in runtimes | assembles Moodle trees from recipes; the plugin/recipe catalogues        |
| [mdl-demo](https://github.com/mutms/mdl-demo)   | any container host      | throwaway all-in-one Moodle demos — pick a version in its web UI         |

## Try it: Sandbox VM

A local VM with a GNOME desktop for trying mpd and
[mudev](https://github.com/mutms/mudev): one script, no host configuration.
Everything an AI agent touches stays inside the VM, and a snapshot rolls it
back. You can adopt it as a managed VM later, projects intact.

Install **Debian Trixie (13) with GNOME** in any hypervisor (8 GB RAM,
4 CPUs, 100 GB disk). Set the hostname to **`mpd-<NNN>`** — a 3-digit id
in 100..254, e.g. `mpd-137`. Snapshot, then run inside the VM:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/setup/mpd-sandbox-setup.sh)
```

It reboots once. Then, for your first Moodle:

```bash
mkdir -p /srv/projects/m45 && cd $_
mudev clone moodle/release/4.5.12       # assemble the tree from a recipe
mpd init                                # register new project
mpd start                               # configure + start the project
mdl-install                             # install Moodle
```

## Daily driver: mpd VM

Same VM, headless: your own browser opens `*.mpd.test`, your IDE connects
over SSH (`ssh mpd-<NNN>` lands in the runtime).
[mpd-virt](https://github.com/mutms/mpd-virt) creates or adopts the VM from
a macOS or Linux host — UTM, Parallels, Apple container, libvirt/KVM,
Proxmox, or any Debian VM it can reach. To adopt a sandbox, run
[setup/mpd-prepare-adopt.sh](setup/mpd-prepare-adopt.sh) inside it, then
`mpd-virt adopt <NNN> --backend=<backend>`.

## Documentation

- [docs/README.md](docs/README.md) — index, audience-shaped
- [docs/usage.md](docs/usage.md) — day-to-day handbook (projects, SSH into
  the runtime, tools, updating)
- [docs/architecture.md](docs/architecture.md) — under the hood
- [AGENTS.md](AGENTS.md) — background, layout, and conventions, for AI
  agents and humans alike

## About

I built these tools for my own daily Moodle work — shaped by 20 years of
Moodle development, standing on my OrbStack-era
[MDC](https://github.com/skodak/mdc) and on
[moodle-docker](https://github.com/moodlehq/moodle-docker) — and I release
them because I like open source. Try them, break them, send issues or PRs.

## AI disclosure

Majority of this project was written with the help of Claude (Anthropic). Everything it
produced was reviewed, corrected where needed and accepted by a human maintainer before
being committed; the design decisions and the final state of the code are the maintainers'.

## License

Copyright (C) 2026 Petr Skoda. [GPL-3.0](LICENSE) or later.

Moodle is a registered trademark of [Moodle Pty Ltd](https://moodle.com).
