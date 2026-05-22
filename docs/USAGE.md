# mpd VM — Usage

Operational handbook for `mpd VM`: bootstrap, first project,
day-to-day.

## Bootstrap (one-time)

You need a Debian Trixie VM with `mpd` built and reachable over SSH.
Pick the path that matches your host:

- **macOS + Parallels Desktop Pro (automated)** —
  [`setup/macos/`](../../setup/macos/README.md).
  Double-click `setup.command`. Clones a one-time-built Parallels VM
  template (`mpd-template`) via `prlctl`, configures the clone
  over SSH, and applies macOS networking (route, resolver, CA).
  Requires Parallels Desktop Pro. `doctor.command` re-applies host
  networking when needed; `uninstall.command` tears everything down.
  VM start / suspend / shutdown is owned by Parallels' GUI.
- **Ubuntu 26.04 LTS + libvirt/KVM (automated)** —
  [`setup/linux/`](../../setup/linux/README.md).
  `bash setup.sh` from a terminal: preflight (apt deps, libvirt group,
  KVM, default network) → libvirt-driven VM creation against `virbr0`
  → Linux host networking (route, systemd-resolved drop-in, system
  trust, Firefox policies, NSS DB) → desktop launcher in GNOME
  Activities. `start.sh` / `stop.sh` / `uninstall.sh` cover the lifecycle.
- **Windows + Hyper-V (automated)** —
  [`setup/windows/`](../../setup/windows/README.txt).
  `setup.cmd` does the same end-to-end and also configures Windows
  networking (route, NRPT DNS, CA certificate import).
- **Sandbox (graphical, any hypervisor)** —
  [`setup/sandbox/`](../../setup/sandbox/README.md).
  You install Debian Trixie with the GNOME desktop in your hypervisor
  of choice (UTM / Parallels / Hyper-V / VirtualBox / virt-manager /
  VMware), snapshot, and run `bash take-over-sandbox-vm.sh` from inside
  the VM. mpd lives entirely inside the VM; the host gets zero
  DNS/route/trust changes.

End state of either path: a VM where `mpd` is on `PATH`, your laptop
SSH key is in `~/.ssh/authorized_keys`, and `~/Developer/mpd/conf/platform.env`
is set.

## `mpd --setup`

SSH into the VM and run:

```bash
mpd --setup
```

Idempotent — safe to re-run any time. Walks you through:

- generating the local CA at `~/Developer/mpd/conf/caroot/`
- installing the CA into the VM's system trust store + Firefox + NSS DB
- configuring `systemd-resolved` to resolve `*.mpd.test` via dnsmasq
- creating the Podman network and data volume
- bringing up the always-on infra services (dnsmasq, portal, Adminer,
  fileaccess) inside the VM
- adding `~/Developer/mpd/bin/machine/` to PATH via a conditional
  block appended to `~/.bashrc` (mirrors Debian's stock
  `~/.local/bin` pattern) so VM-side helpers like `claude-install`
  are reachable from any new shell
- a final DNS sanity check

Host-side trust + WireGuard setup lives in the separate `mpd-virt`
orchestrator (own repo); see its README for the host-side flow.

## Hooking up your laptop (laptop-driven platforms only)

The laptop-driven platforms (macos, linux, windows)
reach the container subnet (`10.163.0.0/24`) over a static route to
the VM, with split DNS pointing `*.mpd.test` at dnsmasq. **Each
platform's bootstrap script applies all of this on the host
automatically** — `setup.command`, `setup.sh`, or `setup.cmd` does
the route + resolver + CA trust in one shot. You normally don't have
to do anything by hand. Concrete network recipes (for the curious or
for recovery) live in [NETWORKING.md](NETWORKING.md).

The **sandbox platform has no laptop side** — mpd lives entirely
inside the VM, so there's no host route, no host resolver drop-in, and
no host CA trust to set up. Open Firefox inside the VM and browse to
`https://mpd.test/`.

## First project — Moodle

### Quick demo (one command)

Inside the VM, `demo` creates a fully installed Moodle site in one shot:

```bash
demo moodle v5.2.0
```

This clones Moodle 5.2.0 from GitHub by tag, provisions the runtime, runs the
database installer, and prints the URL and admin credentials when done.
Takes a few minutes. Idempotent — re-running just starts the existing
project. Other supported flavors: `demo mutms <tag>`.

### Manual setup (full control)

Inside the VM:

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

From your laptop, open `https://moodle51.mpd.test/`. Real cert (signed
by the local CA), no warnings. Outbound mail: visit
`https://mail.moodle51.mpd.test/` and you land on the runtime's shared
Mailpit UI with this project's mail pre-filtered (302-redirect to
`mail.<runtime>.mpd.test/?q=moodle51.mpd.test`). If the project has a
`kind: behat` URL declared, `https://behat.moodle51.mpd.test/` is
wired automatically.

Per-developer defaults (Moodle admin password, Behat preferences, DNS
upstream, etc.) live in `~/.mpd/mpd-user.env` *inside the VM*, synced
into every runtime via the data volume. The full layered
configuration model — file paths, sourcing order, reserved keys — is
documented in
[`../ARCHITECTURE.md` §8](../ARCHITECTURE.md#8-configuration-model-mpdenv).

## SSH into the runtime

This is where the AI-friendly part comes alive. Once a project is
running, the runtime container has a real SSH endpoint at
`<runtime>.runtime.mpd.test`. From your laptop, with the static route
and DNS resolver in place:

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
  start a session inside the runtime. The agent reads/writes files,
  runs composer / phpunit / behat, pushes to GitHub via your
  forwarded agent key.

### IDE connection details from the portal

Open `https://mpd.test/`, click **details** on a running project, and
the popover shows an *Open in IDE* section:

- **VS Code** → one-click `vscode://` Remote-SSH link with host +
  path pre-filled. First click prompts to install the "Remote - SSH"
  extension; subsequent clicks open the project directly.
- **PHPStorm** → connection details (Username / Host / Port / Project
  directory) printed as plain text. JetBrains Gateway's URL-launch
  scheme is restrictive and varies between versions, so we don't ship
  a clickable link — open Gateway, *New Connection → SSH*, and paste
  the four values. Gateway remembers the connection on subsequent
  launches.

The section appears only when the project is running. Project types
that don't hold editable code (e.g. `cftunnel`) opt out via
`"ideLinks": false` in their `configuration.json` and don't render
the section.

If you're inside the VM (e.g. a GNOME terminal in a desktop-in-VM
setup), use the VM-local SSH key instead of `-A`:

```bash
ssh user@php.runtime.mpd.test       # uses ~/.ssh/id_ed25519, no -A needed
```

`mpd --setup` populates each runtime's `authorized_keys` with two key
sources: the laptop key (from the VM's `~/.ssh/authorized_keys`) and
the VM-local key (from `~/.ssh/id_*.pub`, generated by setup if
absent). On the sandbox platform the "laptop key" is just whatever
keys you have authorized for SSHing into the VM (or none, if you only
ever access the sandbox via the hypervisor's console).

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

## Project backups (today)

Backup verbs are on the [roadmap](../ROADMAP.md). Today the workflow
is:

- Inside the runtime, write whatever bundle you want into
  `/srv/backups/` (a data-volume subdirectory).
- From your laptop, pull it off via fileaccess:

  ```bash
  scp fileaccess.service.mpd.test:/srv/backups/<file> ~/Downloads/
  ```

`/srv/backups/` is wiped when the data volume is wiped (`podman volume
rm`, VM reset, etc.). Always pull off before destructive ops you
care about.

## Day-to-day commands

```bash
mpd                              # interactive TUI
mpd --status                     # text status of services + projects

mpd --start                      # reconcile current → requested (start runtimes/projects with state=running)
mpd --stop                       # graceful DB shutdown via EventMpdPreStop, then sudo systemctl poweroff
mpd --restart                    # graceful stop, then sudo systemctl reboot; mpd auto-starts on boot
mpd --check-hooks                # cross-reference asset hook dirs against the Event catalogue

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

A single mpd cftunnel project runs one `cloudflared` connector
(authenticated by a CF tunnel token). The Cloudflare dashboard
controls *which* public hostnames map to *which* internal mpd
projects — one tunnel can serve many moodles. Each target moodle
opts in to external exposure via its own flag, which is the per-
project access control.

**One-time per developer** (host):
```bash
# Add to ~/.mpd/mpd-user.env (replace with the public domain you own):
MPD_UTIL_CFTUNNEL_DOMAIN=.mpd-test.org
```

**Set up the connector** (once per VM, or whenever you rotate tokens):
```bash
# 1. CF dashboard → Networks → Tunnels → Create a Tunnel; copy the token.
mpd create cftunnel                      # name matches the type → autodetected
mpd configure cftunnel MPD_CFTUNNEL_TOKEN=<token-from-cf>
mpd start cftunnel                       # cloudflared connects to CF
```

**Expose a moodle project** (repeat per project to share):
```bash
# 1. CF dashboard → Tunnel → Public Hostnames → Add a public hostname:
#      Subdomain:    moodle520
#      Domain:       mpd-test.org
#      Service Type: HTTPS
#      Service URL:  moodle520.mpd.test
#    (CF auto-creates the DNS CNAME for moodle520.mpd-test.org.)
# 2. Strongly recommended: gate each route with Cloudflare Access
#    so the URL is not reachable by the open internet.
# 3. Enable the moodle-side opt-in:
mpd configure moodle520 MPD_PHP_MOODLE_CFTUNNEL=1
mpd start moodle520
```

That last step is the real gate — Caddy frontdoor only serves the
tunnel hostname for moodles where `MPD_PHP_MOODLE_CFTUNNEL=1` is
set. A moodle project without the flag is unreachable via the tunnel
even if the CF dashboard has a route pointing at it. moodle's
generated URLs (form actions, asset paths) auto-rewrite to the
tunnel hostname when the request arrives via the tunnel; direct
`.mpd.test` access stays internal.

**To unshare**:
```bash
mpd configure moodle520 MPD_PHP_MOODLE_CFTUNNEL=
mpd start moodle520
# (and remove the route in the CF dashboard if you want)
```

**Naming**: project name autodetects the type if it matches a known
type exactly (`mpd create cftunnel` → cftunnel) or ends with
`-<type>` (`mpd create share-cftunnel` → cftunnel). Otherwise pass
`--type=cftunnel` explicitly. The name is purely cosmetic — pick
whatever feels right.

## When you want to start over

A few flavors, increasing severity:

```bash
mpd --runtime-delete php         # nuke a runtime, keep projects + DBs
                                 # (the data volume keeps /srv/projects, /srv/dbs)

# Manual in-VM reset (no --uninstall verb on mpd):
rm -rf ~/.mpd                    # blow away state + identity in the VM

# Nuke the VM itself: hypervisor's VM-delete operation (or, for sandbox,
# revert to your pre-take-over snapshot), then re-bootstrap from any
# setup/<name>/. On macOS hosts: `mpd-virt uninstall <octet>` (separate
# orchestrator binary, own repo) handles the host side cleanly.
```

## Reference

- [README.md](README.md) — when to pick mpd VM, picking a
  hypervisor, prerequisites
- [NETWORKING.md](NETWORKING.md) — host ↔ VM ↔ container routing
- [SECURITY.md](SECURITY.md) — trust boundaries
- [../ARCHITECTURE.md](../ARCHITECTURE.md) — full architecture
- [../CLI_BEHAVIOR.md](../CLI_BEHAVIOR.md) — CLI behavior contract
- [../VISION.md](../VISION.md) — *Why mpd*
- [../ROADMAP.md](../ROADMAP.md) — what's queued next
