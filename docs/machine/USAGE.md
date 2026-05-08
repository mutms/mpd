# mpd-machine — Usage

Operational handbook for `mpd-machine`: bootstrap, first project,
day-to-day. Same shape and same CLI as
[`../desktop/USAGE.md`](../desktop/USAGE.md) — only the host
integration differs.

For the "what is mpd-machine, when do I pick it" framing, see
[README.md](README.md). For the long-form pitch and design rationale,
see [../VISION.md](../VISION.md).

## Bootstrap (one-time)

You need a Debian Trixie VM with `mpd` built and reachable over SSH.
Pick the path that matches your host:

- **macOS + UTM (automated)** —
  [`platforms/macos-utm/`](../../mpd-machine/platforms/macos-utm/README.md).
  `create-vm.sh` does VM creation, cloud-init, repo clone, and `mpd`
  build in one shot.
- **Windows + Hyper-V (automated)** —
  [`platforms/windows-hyperv/`](../../mpd-machine/platforms/windows-hyperv/README.txt).
  `setup.cmd` does the same end-to-end and also configures Windows
  networking (route, NRPT DNS, CA certificate import).
- **Any Debian Trixie VM (manual)** —
  [`platforms/generic-vm/`](../../mpd-machine/platforms/generic-vm/README.md).
  Five-step install from the official netinst ISO. Works on
  libvirt/KVM, QEMU, VirtualBox, cloud, bare-metal sandbox — anywhere
  Debian boots.

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
- installing the CA into the VM's system trust store
- configuring `systemd-resolved` to resolve `*.mpd.test` via dnsmasq
- creating the Podman network and data volume
- bringing up the always-on infra services (dnsmasq, portal, Adminer,
  fileaccess) inside the VM
- adding `~/Developer/mpd/bin/machine/` to login PATH (via
  `/etc/profile.d/mpd-machine.sh`) so VM-side helpers like
  `claude-install` are reachable from a fresh shell
- a final DNS sanity check
- printing the laptop-side recipe at the end (route + DNS resolver +
  optional CA trust, OS-tailored from `conf/platform.env`)

Run `mpd --setup-info` any time to reprint the full plain-text
recipe. Pipeable from your laptop:

```bash
ssh user@vm "mpd --setup-info" > SETUP.txt
```

## Hooking up your laptop

The laptop reaches the container subnet (`10.163.0.0/24`) over a
static route to the VM, with split DNS pointing `*.mpd.test` at
dnsmasq. `mpd --setup` and `mpd --setup-info` both print the exact
commands for your laptop's OS. Concrete recipes live in
[NETWORKING.md](NETWORKING.md).

A typical macOS laptop session looks like:

```bash
sudo route -n add -net 10.163.0.0/24 <vm-ip>
echo "nameserver 10.163.0.3" | sudo tee /etc/resolver/mpd.test >/dev/null
# Optional: trust the CA system-wide for clean HTTPS
scp <vm-ip>:~/Developer/mpd/conf/caroot/rootCA.pem mpd-rootCA.pem
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain mpd-rootCA.pem
```

Verify with `ping mpd.test` and `curl -sS https://mpd.test/`.

## First project — Moodle

### Quick demo (one command)

Inside the VM, `demo` creates a fully installed Moodle site in one shot:

```bash
demo moodle52
```

This clones Moodle 5.2 from GitHub, provisions the runtime, runs the
database installer, and prints the URL and admin credentials when done.
Takes a few minutes. Idempotent — re-running just starts the existing
project.

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

- **PHPStorm Gateway** → connect to `php.runtime.mpd.test` over SSH;
  the editor opens the project at `/srv/projects/moodle51`. Language
  server, Xdebug, phpunit all run inside the runtime.
- **VSCode Remote-SSH** → same endpoint, same shape.
- **Claude Code over SSH** → `ssh -A user@php.runtime.mpd.test` and
  start a session inside the runtime. The agent reads/writes files,
  runs composer / phpunit / behat, pushes to GitHub via your
  forwarded agent key.

If you're inside the VM (e.g. a GNOME terminal in a desktop-in-VM
setup), use the VM-local SSH key instead of `-A`:

```bash
ssh user@php.runtime.mpd.test       # uses ~/.ssh/id_ed25519, no -A needed
```

`mpd --setup` populates each runtime's `authorized_keys` with two key
sources: the laptop key (from the VM's `~/.ssh/authorized_keys`) and
the VM-local key (from `~/.ssh/id_*.pub`, generated by setup if
absent). Full detail and the re-key caveat:
[`platforms/generic-vm/README.md` § "SSH identities"](../../mpd-machine/platforms/generic-vm/README.md#ssh-identities--laptop-key-vm-key-runtime-access).

### Tools available inside the runtime

Once you're SSHed into the runtime, the following tools are on PATH —
project-aware (cwd-walk to find the current project) and ready for
either a human or an AI agent to invoke directly. Full taxonomy in
[`../ARCHITECTURE.md` §7](../ARCHITECTURE.md).

**Base tools (available in every runtime):**

| Tool | What it does |
|---|---|
| `claude-install` | Idempotent install of Claude Code (Anthropic's CLI) to `~/.local/bin/claude` via the upstream `curl \| bash` installer. Re-runs no-op. |
| `node-install` | Idempotent install of nvm + Node.js (LTS by default) into `$HOME/.nvm/` (upstream-standard). After install, `nvm`/`node`/`npm` are on PATH for new login shells; `nvm install <ver>` then works without sudo. Re-runs no-op. |

**Runtime-level (PHP runtime):**

| Tool | What it does |
|---|---|
| `php` | Project-aware PHP wrapper — picks the version pinned in `/srv/meta/<project>/project.json`, falls back to system default. |
| `composer` | The Composer phar; installed at `/usr/local/bin/composer` by `composer-install` at provision time. |
| `composer-install` | Idempotent install of Composer to `/usr/local/bin/`. Re-runs no-op. |
| `composer-upgrade` | Force-reinstalls Composer (bypass idempotency). Use instead of `composer self-update` — the phar is root-owned and self-update can't write to it. |

**Project-type-level (Moodle — available when a Moodle project is in the runtime):**

| Tool | What it does |
|---|---|
| `mdl-install` | Run `admin/cli/install_database.php` for the current project, with composer install + sensible defaults from `mpd.env`. |
| `mdl-cache-purge` | Run `admin/cli/purge_caches.php` for the current project. |
| `mdl-cron` | Run `admin/cli/cron.php` (one cycle) for the current project. |
| `mdl-upgrade` | Run `admin/cli/upgrade.php --non-interactive` for the current project. Use after a git pull that updates code. |
| `mdl-data-purge` | Revert the current project to pre-configured state — drops the DB, wipes dataroots (incl. phpunit + behat), removes generated config files. Preserves `mpd.env` (edit before re-configure to switch DB engine etc.) and the source tree. Prompts for the project name to confirm; pass `--yes` to skip. |
| `phpunit` / `phpunit-init` / `phpunit-util` | Run, initialize, and inspect Moodle's PHPUnit suite. |
| `behat` / `behat-init` / `behat-util` | Run, initialize, and inspect Moodle's Behat suite. |
| `grunt` | Wraps `npm install` + `grunt` for the current project's Moodle JS build. |
| `mpci` / `mpci-install` | Moodle Plugin CI runner and installer. Lives at `/opt/mpd/mpci/` (dev-owned, in the container overlay — re-provision on runtime recreate, like `~/.nvm`). |

The `mdl-` prefix marks Moodle-specific operations whose bare name
would otherwise collide with system commands or be too generic
(`mdl-cron` vs system `cron`). Bare names match upstream tools
(`phpunit`, `behat`, `grunt`).

**Project-type-level (Astro — when an Astro project is in the runtime):**

| Tool | What it does |
|---|---|
| `astro-rebuild` | Stop service, clear `node_modules`, `npm install` + `npm run build`, restart. |
| `astro-upgrade` | Run `npx @astrojs/upgrade`, rebuild, restart the project's systemd unit. |

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
mpd --setup-info                 # reprint laptop-side recipe

mpd --start                      # start mpd services + DNS verify
mpd --stop                       # graceful stop of mpd services
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

## When you want to start over

A few flavors, increasing severity:

```bash
mpd --runtime-delete php         # nuke a runtime, keep projects + DBs
                                 # (the data volume keeps /srv/projects, /srv/dbs)

mpd --uninstall                  # stops mpd, removes ~/.mpd state
                                 # keeps ~/Developer/mpd/conf/ (CA, certs)

# Full reset, in the VM:
mpd --uninstall && rm -rf ~/Developer/mpd/conf/

# Nuke the VM itself: hypervisor's VM-delete operation, then re-bootstrap
# from platforms/macos-utm/ or platforms/generic-vm/.
```

`conf/` survives `--uninstall` by design — same CA tomorrow means same
cert trust tomorrow. Wipe the VM only when you genuinely want to start
from a blank disk.

## Reference

- [README.md](README.md) — when to pick mpd-machine, picking a
  hypervisor, prerequisites
- [NETWORKING.md](NETWORKING.md) — host ↔ VM ↔ container routing
- [SECURITY.md](SECURITY.md) — trust boundaries
- [../ARCHITECTURE.md](../ARCHITECTURE.md) — full architecture
- [../CLI_BEHAVIOR.md](../CLI_BEHAVIOR.md) — CLI behavior contract
- [../VISION.md](../VISION.md) — *Why mpd*
- [../ROADMAP.md](../ROADMAP.md) — what's queued next
