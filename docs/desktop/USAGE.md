# mpd-desktop — Usage

Operational handbook for `mpd-desktop`: install, first project,
day-to-day. Aim for **zero to `https://moodle51.mpd.test/` in about
ten minutes** the first time, two minutes thereafter.

For the "what is mpd-desktop, when do I pick it" framing, see
[README.md](README.md). For the long-form pitch and design rationale,
see [../VISION.md](../VISION.md).

## Install

Prerequisites (full list in [README.md](README.md#prerequisites)):

- macOS on Apple Silicon
- [Podman Desktop](https://podman-desktop.io/) installed and running,
  with a **rootful** machine named `mpd-desktop` created and started in
  its UI (concurrent variants are also accepted —
  `mpd-desktop-<suffix>` where `<suffix>` is lowercase alphanumeric,
  e.g. `mpd-desktop-stable`, `mpd-desktop-dev`)
- [WireGuard for macOS](https://apps.apple.com/app/wireguard/id1451685025)
  installed
- Xcode command-line tools: `xcode-select --install`

Clone and build:

```bash
git clone https://github.com/mutms/mpd.git ~/Developer/mpd
cd ~/Developer/mpd
make install
```

That writes the binary to `~/Developer/mpd/bin/mpd`. **Do not copy this
binary elsewhere** — `mpd` enforces running from this exact path so
relative path checks against `assets/` and `conf/` stay honest.

Add it to your `PATH`:

```bash
echo 'export PATH="$HOME/Developer/mpd/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

## `mpd --setup`

```bash
mpd --setup
```

Idempotent — safe to re-run any time. Adopts whichever
`mpd-desktop[-<suffix>]` Podman machine you currently have running,
persists it as the active machine for `mpd --start`/`--stop`, then
walks you through:

- generating the local CA at `~/Developer/mpd/conf/caroot/`
- adding the CA to your macOS Keychain (system trust)
- creating `/etc/resolver/mpd.test` so `*.mpd.test` resolves locally
- generating the WireGuard tunnel config and prompting you to import
  it into the WireGuard app (enable "On Demand" while you're there)
- bringing up the always-on infra services (dnsmasq, portal, Adminer,
  fileaccess) inside the Podman machine VM
- a final DNS sanity check

`mpd --setup` does not create Podman machines — that's your job in
the Podman Desktop UI. The flow is: create + start the machine
(named `mpd-desktop` or `mpd-desktop-<suffix>`), then run `mpd
--setup`. It errors out if no Podman machine is running, if more
than one is running, or if the running one isn't an mpd-desktop
machine.

Re-running `mpd --setup` against a different `mpd-desktop-<suffix>`
that mpd has seen before switches to it silently. A brand-new name
prompts for confirmation before adoption.

You can run `mpd --setup-info` any time to reprint the laptop-side
recipe (WireGuard import path, CA trust verify, resolver file path,
verify steps, uninstall block).

## First project — Moodle

```bash
# 1. Scaffold (clone + seed mpd.env from the type's template; no DB yet)
mpd create moodle51 \
  --git-repo=https://github.com/moodle/moodle.git \
  --git-branch=MOODLE_501_STABLE

# 2. (optional) override defaults before configure:
#      mpd configure moodle51 MPD_DB=postgres:18
#      mpd configure moodle51 MPD_PHP_VERSION=8.4
#    Or edit /srv/projects/moodle51/mpd.env directly.

# 3. Configure — provisions the DB container, creates the DB,
#    writes config.php, runs the Moodle install.
mpd configure moodle51

# 4. Start the project.
mpd start moodle51
```

Open `https://moodle51.mpd.test/` in your browser. Real cert (signed by
the local CA you trusted in setup), no warnings. Outbound mail: visit
`https://mail.moodle51.mpd.test/` and you land on the runtime's shared
Mailpit UI with this project's mail pre-filtered (302-redirect to
`mail.<runtime>.mpd.test/?q=moodle51.mpd.test`). If the project has a
`kind: behat` URL declared, `https://behat.moodle51.mpd.test/` is
wired automatically by the runtime's Caddy frontdoor.

Per-developer defaults that span every project (Moodle admin password,
Behat preferences, DNS upstream, etc.) live in `~/.mpd/mpd-user.env`
on the Mac, synced into every runtime via the data volume. The full
layered configuration model — file paths, sourcing order, reserved
keys — is documented in
[`../ARCHITECTURE.md` §8](../ARCHITECTURE.md#8-configuration-model-mpdenv).

## SSH into the runtime

This is where the AI-friendly part comes alive. Once a project is
running, the runtime container has a real SSH endpoint at
`<runtime>.runtime.mpd.test`:

```bash
ssh -A user@php.runtime.mpd.test
```

You land in the runtime as your local user (UID matched), with
passwordless sudo, agent-forwarded git auth, and the project tree at
`/srv/projects/<project>/`. From there:

- **VS Code Remote-SSH** → connect to `php.runtime.mpd.test`, open
  `/srv/projects/<project>/`. Language server, debugger, terminals
  all run inside the runtime.
- **PHPStorm Gateway** → same endpoint, same shape.
- **Claude Code over SSH** → `ssh -A user@php.runtime.mpd.test` and
  start a session inside the runtime. The agent can read/write files,
  run composer / phpunit / behat, push to GitHub via your forwarded
  agent key.

The host stays the thin coordination layer; the runtime is the
workspace.

### One-click IDE launch from the portal

You don't have to remember any of the connection details. Open
`https://mpd.test/`, click **details** on a running project, and the
popover shows two buttons:

- **VS Code** → `vscode://` Remote-SSH link with host + path
  pre-filled. First click prompts to install the "Remote - SSH"
  extension; subsequent clicks open the project directly.
- **PHPStorm** → `jetbrains-gateway://` link with the same
  pre-filled connection details. Requires JetBrains Gateway
  installed; opens the connect dialog with everything ready.

Buttons appear only when the project is running. Project types that
don't hold editable code (e.g. `cftunnel`) opt out via
`"ideLinks": false` in their `configuration.json` and don't render
the section.

### Tools available inside the runtime

Once you're SSHed into the runtime, the following tools are on PATH —
project-aware (cwd-walk to find the current project) and ready for
either a human or an AI agent to invoke directly. Full taxonomy in
[`../ARCHITECTURE.md` §7](../ARCHITECTURE.md).

**Base tools (available in every runtime):**

| Tool             | What it does                                                                                                                                                                                                                 |
|------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `claude-install` | Idempotent install of Claude Code (Anthropic's CLI) to `~/.local/bin/claude` via the upstream `curl \| bash` installer. Re-runs no-op.                                                                                       |
| `node-install`   | Idempotent install of nvm + Node.js (LTS by default) into `$HOME/.nvm/` (upstream-standard). After install, `nvm`/`node`/`npm` are on PATH for new login shells; `nvm install <ver>` then works without sudo. Re-runs no-op. |

**Runtime-level (PHP runtime):**

| Tool               | What it does                                                                                                                                      |
|--------------------|---------------------------------------------------------------------------------------------------------------------------------------------------|
| `php`              | Project-aware PHP wrapper — picks the version pinned in `/srv/meta/<project>/project.json`, falls back to system default.                         |
| `composer`         | The Composer phar; installed at `/usr/local/bin/composer` by `composer-install` at provision time.                                                |
| `composer-install` | Idempotent install of Composer to `/usr/local/bin/`. Re-runs no-op.                                                                               |
| `composer-upgrade` | Force-reinstalls Composer (bypass idempotency). Use instead of `composer self-update` — the phar is root-owned and self-update can't write to it. |

**Project-type-level (Moodle — available when a Moodle project is in the runtime):**

| Tool                                        | What it does                                                                                                                                                                                                                                                                                            |
|---------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `mdl-install`                               | Run `admin/cli/install_database.php` for the current project, with composer install + sensible defaults from `mpd.env`.                                                                                                                                                                                 |
| `mdl-cache-purge`                           | Run `admin/cli/purge_caches.php` for the current project.                                                                                                                                                                                                                                               |
| `mdl-cron`                                  | Run `admin/cli/cron.php` (one cycle) for the current project.                                                                                                                                                                                                                                           |
| `mdl-upgrade`                               | Run `admin/cli/upgrade.php --non-interactive` for the current project. Use after a git pull that updates code.                                                                                                                                                                                          |
| `mdl-data-purge`                            | Revert the current project to pre-configured state — drops the DB, wipes dataroots (incl. phpunit + behat), removes generated config files. Preserves `mpd.env` (edit before re-configure to switch DB engine etc.) and the source tree. Prompts for the project name to confirm; pass `--yes` to skip. |
| `phpunit` / `phpunit-init` / `phpunit-util` | Run, initialize, and inspect Moodle's PHPUnit suite.                                                                                                                                                                                                                                                    |
| `behat` / `behat-init` / `behat-util`       | Run, initialize, and inspect Moodle's Behat suite.                                                                                                                                                                                                                                                      |
| `grunt`                                     | Wraps `npm install` + `grunt` for the current project's Moodle JS build.                                                                                                                                                                                                                                |
| `mpci` / `mpci-install`                     | Moodle Plugin CI runner and installer. Lives at `/opt/mpd/mpci/` (dev-owned, in the container overlay — re-provision on runtime recreate, like `~/.nvm`).                                                                                                                                               |

The `mdl-` prefix marks Moodle-specific operations whose bare name
would otherwise collide with system commands or be too generic
(`mdl-cron` vs system `cron`). Bare names match upstream tools
(`phpunit`, `behat`, `grunt`).

**Project-type-level (Astro — when an Astro project is in the runtime):**

| Tool            | What it does                                                                  |
|-----------------|-------------------------------------------------------------------------------|
| `astro-rebuild` | Stop service, clear `node_modules`, `npm install` + `npm run build`, restart. |
| `astro-upgrade` | Run `npx @astrojs/upgrade`, rebuild, restart the project's systemd unit.      |

The `astro-` prefix follows the same rule as `mdl-` — disambiguation
for project-type-specific operations whose bare name (`rebuild`,
`upgrade`) would be too generic.

## Day-to-day commands

```bash
mpd                              # interactive TUI
mpd --status                     # text status of services + projects
mpd --setup-info                 # reprint laptop-side recipe

mpd --start                      # start the active mpd-desktop machine + services + tunnel; reconcile state
mpd --stop                       # graceful DB shutdown via EventMpdPreStop, then stop the Podman machine
mpd --restart                    # graceful stop + Podman machine restart (run `mpd --start` after to restore projects)
mpd --check-hooks                # cross-reference asset hook dirs against the Event catalogue
mpd --uninstall                  # remove ~/.mpd state, keep conf/

mpd list                         # list all projects (default)
mpd list runtimes                # list runtime containers
mpd list services                # list always-on infra services
mpd list dbs                     # list DB containers

mpd <project>                    # show project info
mpd create <project> [...]       # scaffold a new project
mpd configure <project> [K=V]    # apply mpd.env, (re)provision DB
mpd start <project> / stop       # run/halt the project
mpd delete <project>             # remove the project
mpd help <project>               # all verbs for this project type

mpd --runtime=<name>             # show one runtime's details
mpd --runtime-create=<name>      # provision a new runtime
mpd --runtime-stop=<name>        # stop one
mpd --runtime-delete=<name>      # remove one (prompts unless --yes)

mpd --help                       # full flag reference
```

## Sharing a project externally (Cloudflare Tunnel)

Same shape as on mpd-machine — see
[machine/USAGE.md](../machine/USAGE.md#sharing-a-project-externally-cloudflare-tunnel)
for the full workflow. Single cftunnel project per VM holds the CF
token + runs the connector; CF dashboard controls which public
hostnames map to which internal mpd projects; each moodle
individually opts in to external exposure via
`MPD_PHP_MOODLE_CFTUNNEL=1`.

## When you want to start over

```bash
mpd --uninstall      # stops mpd, removes ~/.mpd state
                     # keeps ~/Developer/mpd/conf/ (CA, WG keys)
mpd --setup          # rebuilds, re-trusts, re-imports
```

`conf/` survives by design — your tomorrow self should not have to
re-trust the CA. If you want a fully clean slate including the CA:
`rm -rf ~/Developer/mpd/conf/` before re-running `--setup`.

## Reference

- [README.md](README.md) — when to pick mpd-desktop, prerequisites
- [NETWORKING.md](NETWORKING.md) — gvproxy / WireGuard / dnsmasq design
- [SECURITY.md](SECURITY.md) — trust boundaries
- [../ARCHITECTURE.md](../ARCHITECTURE.md) — full architecture
- [../CLI_BEHAVIOR.md](../CLI_BEHAVIOR.md) — CLI behavior contract
- [../VISION.md](../VISION.md) — *Why mpd*
