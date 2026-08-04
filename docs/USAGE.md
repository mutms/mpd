# Usage

Operational handbook for `mpd`: bootstrap, first project, day-to-day.
Applies to **both Sandbox VM and mpd VM modes** — the CLI surface is
identical once `mpd --vm-setup` has run. Mode-specific notes are called
out where they matter.

## Bootstrap (one-time)

You need a Debian Trixie VM with `mpd` built and reachable over SSH.
Pick the path that matches your host:

- **macOS + Parallels / UTM / Proxmox / cloud (automated)** —
  [`mpd-virt`](https://github.com/mutms/mpd-virt) (separate repo).
  `mpd-virt takeover <NNN> <IP>` adopts any reachable Debian Trixie box:
  it runs the bootstrap pipeline over SSH, installs `mpd`, and wires host
  reachability — the **mpd-proxy WireGuard overlay** for daily transparent
  access, or a **SOCKS-over-SSH** fallback (`ssh -N mpd-<NNN>-socks`) that
  needs no sudo. `mpd-virt delete` / `uninstall` tear things down; VM power
  (where the backend supports it) via `mpd-virt start|stop` or the
  hypervisor's GUI.
- **Ubuntu 26.04 LTS + libvirt/KVM (automated)** —
  [`setup/linux/`](../setup/linux/README.md).
  `bash setup.sh` from a terminal: preflight (apt deps, libvirt group,
  KVM, default network) → libvirt-driven VM creation against `virbr0`
  → Linux host networking (route, systemd-resolved drop-in, system
  trust, Firefox policies, NSS DB) → desktop launcher in GNOME
  Activities. `start.sh` / `stop.sh` / `uninstall.sh` cover the lifecycle.
- **Windows + Hyper-V (automated)** —
  [`setup/windows/`](../setup/windows/README.txt).
  `setup.cmd` does the same end-to-end and also configures Windows
  networking (route, NRPT DNS, CA certificate import).
- **Sandbox (graphical, any hypervisor)** —
  [`setup/sandbox/`](../setup/sandbox/README.md).
  You install Debian Trixie with the GNOME desktop in your hypervisor
  of choice (UTM / Parallels / Hyper-V / VirtualBox / virt-manager /
  VMware), snapshot, and run `bash take-over-sandbox-vm.sh` from inside
  the VM. mpd lives entirely inside the VM; the host gets zero
  DNS/route/trust changes.

End state of either path: a VM where `mpd` is on `PATH`, your laptop
SSH key is in `~/.ssh/authorized_keys`.

## `mpd --vm-setup`

SSH into the VM and run:

```bash
mpd --vm-setup
```

Idempotent — safe to re-run any time. Walks you through:

- generating the local CA at `/var/lib/mpd/conf/caroot/`
- installing the CA into the VM's system trust store + Firefox + NSS DB
- creating the Podman network and data volume
- mounting the data volume on the VM at `/srv`
- installing and configuring caddy, the VM's TLS frontdoor
- starting `mpd --web`, the status page at `https://<NNN>.mpd.test/`
- bringing up the always-on infra containers (dnsmasq, Adminer)
- a final DNS sanity check

(VM-side apt installs, network stack setup, hostname/IP canonicalization,
`mpd` build, and `/opt/mpd/bin/` on PATH all happen earlier in the
`bootstrap/30..50` steps and don't re-run here. See `bootstrap/README.md`.)

Host-side trust + networking setup lives in the separate `mpd-virt`
orchestrator (own repo); see its README for the host-side flow.

## Hooking up your laptop (laptop-driven platforms only)

The laptop reaches only the VM's gateway `.1` (caddy + dnsmasq) — the
container subnet is sealed from outside. Two host-side paths, both set up
by `mpd-virt`: the **mpd-proxy WireGuard overlay** (transparent, every
app, several VMs at once — needs sudo once) for daily use, or the
sudo-free **SOCKS-over-SSH** tunnel (`ssh -N mpd-<NNN>-socks` + a dedicated
browser) as the simple starting point. Either way CA trust makes
`*.mpd.test` HTTPS work. Concrete network recipes (for the curious or for
recovery) live in [NETWORKING.md](NETWORKING.md).

The **sandbox platform has no laptop side** — mpd lives entirely
inside the VM, so there's no host route, no host resolver drop-in, and
no host CA trust to set up. Open Firefox inside the VM and browse to
`https://<NNN>.mpd.test/`.

## First project — Moodle

### Quick demo (one command)

Inside the VM, `demo` creates a fully installed Moodle site in one shot:

```bash
demo moodle/release/4.5.12 demo45
```

The first argument is a mudev recipe — a Moodle branch plus a plugin set
plus config — resolved from `/srv/extra/mdl-recipes/` by identifier, or
read from a path. The second is the project name. Run `demo` with no
arguments to list the recipes present on this VM.

`mudev clone` assembles the tree, then mpd provisions the runtime and
database, installs Moodle, and prints the URL and admin credentials.
Takes a few minutes. Idempotent — re-running just starts the existing
project.

### Manual setup (full control)

Inside the VM:

```bash
# 1. Get the source. /srv is mounted on the VM, so this is ordinary shell —
#    a mudev recipe, or any git clone you like.
mkdir -p /srv/projects/moodle51 && cd /srv/projects/moodle51
mudev clone moodle/release/5.1.5
#    or: git clone -b MOODLE_501_STABLE https://github.com/moodle/moodle.git .

# 2. Scaffold (seeds mpd.env from the type's template; no DB yet).
#    No project name needed — it comes from the directory you are in.
mpd create --type=moodle

# 3. (optional) override defaults before configure:
#      mpd configure MPD_DB=postgres:18
#      mpd configure MPD_PHP_VERSION=8.4
#    Or edit /srv/projects/moodle51/mpd.env directly.

# 3. Configure — provisions the DB container, creates the DB,
#    writes config.php, runs the Moodle install.
mpd configure moodle51

# 4. Start the project.
mpd start moodle51
```

From your laptop, open `https://moodle51.<NNN>.mpd.test/`. Real cert (signed
by the local CA), no warnings. Outbound mail: visit
`https://mail.moodle51.<NNN>.mpd.test/` and you land on the runtime's shared
Mailpit UI with this project's mail pre-filtered (302-redirect to
`mail.<runtime>.<NNN>.mpd.test/?q=moodle51.<NNN>.mpd.test`). If the project has a
`kind: behat` URL declared, `https://behat.moodle51.<NNN>.mpd.test/` is
wired automatically.

VM-wide defaults (Moodle admin password, Behat preferences, Cloudflare
Tunnel domain, etc.) live in `/var/lib/mpd/env/mpd-vm.env` *inside the VM*
and are bind-mounted RO into every runtime container — edit on the host
and the new values are visible to the next command run inside any runtime.
The full layered
configuration model — file paths, sourcing order, reserved keys — is
documented in
[`ARCHITECTURE.md` §8](ARCHITECTURE.md#8-configuration-model-mpdenv).

## Running runtime commands from the VM

`mpd run` forwards a command into the runtime that owns the project you
are standing in, so a one-off does not need an SSH hop:

```bash
cd /srv/projects/moodle51
mpd run php admin/cli/install_database.php --agree-license --adminpass=…
mpd run mdl-cron
mpd run composer install
```

Your working directory is forwarded as-is — `/srv` is the same tree at
the same path on both sides — and the command runs with the runtime's
own PATH, so every tool below is available. Exit codes propagate, so it
composes in scripts. Outside `/srv/projects/<name>/` it refuses rather
than guessing which project you meant.

For a session rather than a command, SSH in.

## SSH into the runtime

This is where the AI-friendly part comes alive. Once a project is
running, the runtime container has a real SSH endpoint. From your laptop,
use the ProxyJump alias `mpd-virt` wrote — the container IP itself is
sealed, so the jump rides the VM's sshd (which also means it works with no
overlay or proxy running):

```bash
ssh -A mpd-<NNN>-php
```

Inside the VM the same alias works without the jump. Add `-A` only when
that runtime genuinely needs your SSH agent — see [SECURITY.md](SECURITY.md).

You land in the runtime as your local user (UID matched), with
passwordless sudo, agent-forwarded git auth, and the project tree at
`/srv/projects/<project>/`. From there:

- **VS Code Remote-SSH** → connect to `php.runtime.<NNN>.mpd.test`, open
  `/srv/projects/<project>/`. Language server, debugger, terminals
  all run inside the runtime.
- **PHPStorm Gateway** → same endpoint, same shape.
- **Claude Code over SSH** → `ssh -A user@php.runtime.<NNN>.mpd.test` and
  start a session inside the runtime. The agent reads/writes files,
  runs composer / phpunit / behat, pushes to GitHub via your
  forwarded agent key.

### IDE connection details from the portal

Open `https://<NNN>.mpd.test/`, click **details** on a running project, and
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
setup), use the VM-local SSH key instead of `-A` — and there is a short
alias for every runtime:

```bash
ssh mpd-<NNN>-php                         # the short alias mpd writes for you
ssh php                                   # same thing, in-VM shorthand
ssh user@php.runtime.<NNN>.mpd.test       # the long form still works
```

All three use `~/.ssh/id_ed25519`, so no `-A` is needed. The aliases are
a managed block `mpd --vm-setup` writes into the dev user's
`~/.ssh/config`, one entry per runtime in the assets tree — it fills in
the user, points the alias at the real name, and skips host-key
verification, which a container that gets recreated on demand would
otherwise trip over on every rebuild. Only the FQDN is in DNS; the short
names are an ssh-level convenience, so they work for `ssh`, `scp` and
`rsync` but not in a browser.

Anything you write *outside* the `# >>> mpd runtimes ... >>>` markers is
preserved across re-runs; anything inside them is regenerated. An alias
for a runtime you haven't provisioned yet fails to resolve, exactly as
the long form would.

`mpd-<NNN>-php` is also the runtime container's own hostname, so your
shell prompt after connecting echoes what you typed. It's the same
string the workstation's `~/.ssh/config` uses for the hop in from
outside, so the command reads the same in both places.

`mpd --vm-setup` populates each runtime's `authorized_keys` with two key
sources: the laptop key (from the VM's `~/.ssh/authorized_keys`) and
the VM-local key (from `~/.ssh/id_*.pub`, generated by setup if
absent). On the sandbox platform the "laptop key" is just whatever
keys you have authorized for SSHing into the VM (or none, if you only
ever access the sandbox via the hypervisor's console).

## `mpd` from inside the runtime

You don't need a second terminal to drive mpd. `mpd` is on `PATH` inside
every runtime and the project verbs work there:

```bash
ssh mpd-<NNN>-php
cd /srv/projects/newproject          # a directory that isn't a project yet
mpd create --type=moodle             # scaffolds it, in THIS runtime
mpd configure newproject
mpd start newproject
mpd show newproject
```

It is the same binary — `/opt/mpd` is bind-mounted read-only, so there is
no second build to keep in step. It notices it is inside a runtime, sends
the command to the VM over that runtime's control socket, and the VM runs
it. Because your terminal's own file descriptors are handed to the process
on the VM, output streams live and in colour, exit codes propagate into
`$?`, and a confirmation prompt like `mpd delete`'s reads your keystrokes.

**Only project verbs**: `create`, `configure`, `start`, `stop`, `delete`,
`show`, `help`. Everything that acts on the VM or its infrastructure
stays in a VM terminal — no `--vm-*`, no `--runtime-*`, no `--db-*`. A
runtime has no business building runtimes or database containers.
`mpd run` is refused too: you are already in the runtime, so run the
command directly.

**You can only touch your own runtime's projects.** From the `php`
runtime, a `node` project is refused by name, and so is standing in its
directory:

```
$ mpd start site
Error: cannot act on project 'site' from the 'php' runtime — it belongs to 'node'.
Run it from a VM terminal, or from that runtime.
```

Two details worth knowing:

- **`--type` is constrained, not optional.** It still says what kind of
  project to build, but it must be a type this runtime serves — otherwise
  `mpd create --type=astro` from `php` would quietly build the whole
  `node` runtime. Where a runtime serves exactly one type (php serves
  only `moodle`), you can leave `--type` out and mpd fills it in.
- **`cd` where it matters.** Inside `/srv/projects/<name>/` the project
  name is inferred, exactly as on the VM. Elsewhere — including the
  `$HOME` you land in when you SSH in — name the project explicitly;
  `/srv` is the only tree that means the same thing on both sides.

To turn the whole thing off, set `MPD_RUNTIME_CONTROL=off` in
`/var/lib/mpd/env/mpd-vm.env`; it applies to the next command, no restart.
The trade-off it exists for is in
[`SECURITY.md`](SECURITY.md#the-runtime-control-socket).

### Pushing to git from inside the runtime

Runtimes don't carry your private SSH key. Authenticate to
GitHub/GitLab/private remotes via **SSH agent forwarding** (`ssh -A`):

```bash
ssh-add ~/.ssh/id_ed25519           # load the key into your laptop's agent
                                    # (once per laptop session)
ssh -A user@php.runtime.<NNN>.mpd.test    # -A forwards the agent socket in
cd /srv/projects/moodle51
git push origin main                # forwarded agent signs; the remote
                                    # sees your laptop's key
```

VSCode Remote-SSH forwards the agent silently
(`remote.ssh.enableAgentForwarding` is on by default). PHPStorm Gateway
also forwards by default but prompts on each key access — use
per-access prompts when an AI agent is driving, per-session when you're
typing. An AI agent launched inside an `-A` SSH session uses the same
forwarded socket — `git push` from the agent authenticates against your
GitHub account via your laptop's key.

The private key **never leaves the laptop**. The runtime can request
signatures via the agent's API only while your SSH session is open —
there's no way to extract the key. Close the session, auth goes away.
Wipe or compromise the runtime, your key is unaffected.

**One more guard.** Agent forwarding lets the AI push commits *under
your identity* — so the consequence-blocking moves to the remote, not
the runtime. Minimum recommended: **block force-pushes on protected
branches** (`main`, release branches) under *GitHub Settings →
Branches*. Every change the AI makes lands as an append-only commit
you can audit. Stricter shops also require PRs for `main`.

### Tools available inside the runtime

Once you're SSHed into the runtime, the following tools are on PATH —
project-aware (cwd-walk to find the current project) and ready for
either a human or an AI agent to invoke directly. Full taxonomy in
[`ARCHITECTURE.md` §7](ARCHITECTURE.md).

**Base tools (available in every runtime):**

| Tool             | What it does                                                                                                                                                                                                                 |
|------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `claude-install` | Idempotent install of Claude Code (Anthropic's CLI) to `~/.local/bin/claude` via the upstream `curl \| bash` installer. Re-runs no-op.                                                                                       |
| `node-install`   | Idempotent install of nvm + Node.js (LTS by default) into `$HOME/.nvm/` (upstream-standard). After install, `nvm`/`node`/`npm` are on PATH for new login shells; `nvm install <ver>` then works without sudo. Re-runs no-op. |

**Runtime-level (PHP runtime):**

| Tool               | What it does                                                                                                                                      |
|--------------------|---------------------------------------------------------------------------------------------------------------------------------------------------|
| `php`              | Project-aware PHP wrapper, registered as the Debian `php` alternative (so `/usr/bin/php` is it) — picks the project's `MPD_PHP_VERSION`, falls back to 8.2 outside a project tree. |
| `composer`         | The Composer phar; installed at `/usr/local/bin/composer` by `composer-install` at provision time.                                                |
| `composer-install` | Idempotent install of Composer to `/usr/local/bin/`. Re-runs no-op.                                                                               |
| `composer-upgrade` | Force-reinstalls Composer (bypass idempotency). Use instead of `composer self-update` — the phar is root-owned and self-update can't write to it. |
| `mudev`            | Assembles a Moodle tree from a recipe. Built on the VM by `mpd --vm-setup` at `/opt/mudev`, bind-mounted read-only into every runtime, so the same binary answers on the VM and in any runtime. Its catalogues live in `/srv/extra/`. |

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

Backup verbs are on the [roadmap](ROADMAP.md). Today the workflow
is:

- Inside the runtime, write whatever bundle you want into
  `/srv/backups/` (a data-volume subdirectory).
- From your laptop, scp it off the VM — `/srv` is mounted there:

  ```bash
  scp <vm>:/srv/backups/<file> ~/Downloads/
  ```

`/srv/backups/` is wiped when the data volume is wiped (`podman volume
rm`, VM reset, etc.). Always pull off before destructive ops you
care about.

## Starting over without re-cloning: `mpd reset`

`mpd reset <project>` throws away everything a project generated and puts
it back in the state `mpd create` left it in, **keeping the source tree**.
Two things it is for:

```bash
# The database is corrupted, or the data is not worth keeping.
mpd reset moodle45
mpd configure moodle45            # fresh, empty database
mpd start moodle45
# then install Moodle again from the runtime: ssh mpd-<NNN>-php, mdl-install

# Switch database engine on an existing site.
mpd reset moodle45
vi /srv/projects/moodle45/mpd.env  # MPD_DB=postgres:18
mpd configure moodle45            # config-mpd.php regenerated for the new engine
mpd start moodle45
```

**Kept:** `/srv/projects/<project>/` — the code, git history, `mpd.env`
and `config.php`. That is the point: nothing is re-cloned and no
hand-edited settings are lost. `config.php` is written only when missing,
while `config-mpd.php` (wwwroot, dataroot, DB credentials) is regenerated
on every `configure` — which is what lets the database change underneath
an unchanged `config.php`.

**Destroyed:** the project's database, everything inside
`/srv/data/<project>/` (dataroot plus the behat and phpunit ones), the
generated metadata in `/srv/meta/<project>/` including its TLS
certificate, and the project's DNS record.

**Left not configured.** Afterwards the project has no database, no
dataroot and no runtime assignment, so `mpd start` refuses until you run
`mpd configure`. That is also what makes the engine switch work, since
`configure` is what reads the new `MPD_DB`.

The database *engine container* keeps running. It is shared by every
project on that `engine:version`, so stopping it would reach outside this
project, and an idle engine costs nothing.

Both `reset` and `delete` ask you to **type the project name** rather than
answering `y/N` — `y` is the same keystroke whichever project the prompt is
about, so a mistyped name plus a reflexive `y` is a plausible way to lose
the wrong site. `--yes` skips the question for scripted use.

## Day-to-day commands

```bash
mpd                              # status (a bare mpd falls through to --vm-status)
mpd --vm-status                     # text status of services + projects

mpd --vm-start                      # reconcile current → requested (start runtimes/projects with state=running)
mpd --vm-stop                       # graceful DB shutdown via EventMpdPreStop, then sudo systemctl poweroff
mpd --vm-restart                    # graceful stop, then sudo systemctl reboot; mpd auto-starts on boot
mpd --check-hooks                # cross-reference asset hook dirs against the Event catalogue

mpd list                         # list all projects (default)
mpd list runtimes                # list runtime containers
mpd list services                # list always-on infra services
mpd list dbs                     # list DB containers

mpd <project>                    # show project info
mpd create <project> [...]       # scaffold a new project
mpd configure <project> [K=V]    # apply mpd.env, (re)provision DB
mpd start <project> / stop       # run/halt the project
mpd reset <project>              # destroy DB + data, keep the code (type the name to confirm)
mpd delete <project>             # remove the project entirely (type the name to confirm)
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
# Add to /var/lib/mpd/env/mpd-vm.env (replace with the public domain you own):
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
#      Service URL:  moodle520.<NNN>.mpd.test
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
mpd --runtime-delete php         # delete a runtime, keep projects + DBs
                                 # (the data volume keeps /srv/projects, /srv/dbs)

# Container-layer reset. The first thing to try after upgrading mpd across
# changes that alter container shape — new mounts, labels, images, or a
# service that moved out of a container entirely. Everything mpd creates is
# rebuilt from scratch; nothing you made is touched, because projects, DB
# data and mpd state live outside the containers.
sudo podman rm -af               # every mpd container, running or not
sudo podman network rm mpd-internal

mpd --vm-setup                   # network + services + units, from scratch
mpd --runtime-create=php         # runtimes are NOT recreated by `mpd start`:
                                 # it starts what exists and says so if it does not
mpd --db-create=postgres:latest  # nor are DB containers. Their data survives in
                                 # /srv/dbs/<id>/, so the databases come back with
                                 # the container — but until it exists, every
                                 # project answers "Database connection failed"
mpd start <project>              # per project you want back up

# Manual in-VM reset (no --uninstall verb on mpd):
rm -rf /var/lib/mpd                    # blow away state + identity in the VM

# Delete the VM itself: hypervisor's VM-delete operation (or, for sandbox,
# revert to your pre-take-over snapshot), then re-bootstrap from any
# setup/<name>/. On macOS hosts: `mpd-virt uninstall <octet>` (separate
# orchestrator binary, own repo) handles the host side cleanly.
```

## Reference

- [README.md](README.md) — documentation index (audience-shaped)
- [../README.md](../README.md) — top-level pitch + mode picker + first bootstrap
- [NETWORKING.md](NETWORKING.md) — host ↔ VM ↔ container routing
- [SECURITY.md](SECURITY.md) — trust boundaries
- [ARCHITECTURE.md](ARCHITECTURE.md) — full architecture
- [CLI_BEHAVIOR.md](CLI_BEHAVIOR.md) — CLI behavior contract
- [ROADMAP.md](ROADMAP.md) — what's queued next
