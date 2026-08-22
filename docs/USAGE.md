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
  `mpd-virt adopt <NNN> <IP>` adopts any reachable Debian Trixie box:
  it runs the bootstrap pipeline over SSH, installs `mpd`, and wires host
  reachability — the **mpd-proxy WireGuard overlay** for daily transparent
  access, or a **SOCKS-over-SSH** fallback (`ssh -N mpd-<NNN>-socks`) that
  needs no sudo. `mpd-virt remove` / `uninstall` un-adopt and tear the host side down; VM power
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
  [`setup/mpd-sandbox-setup.sh`](../setup/mpd-sandbox-setup.sh).
  You install Debian Trixie with the GNOME desktop in your hypervisor
  of choice (UTM / Parallels / Hyper-V / VirtualBox / virt-manager /
  VMware), snapshot, and run the script from inside the VM (wget
  one-liner in the top-level README). mpd lives entirely inside the
  VM; the host gets zero DNS/route/trust changes.

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
- quieting the kernel console to warnings and errors
  (`/etc/sysctl.d/99-mpd-printk.conf`)
- creating the Podman network and data volume
- mounting the data volume on the VM at `/srv`
- installing and configuring the VM's caddy, which serves the portal at
  `https://<NNN>.mpd.test/` (project HTTPS terminates inside the
  runtime — see [NETWORKING.md](NETWORKING.md))
- starting `mpd --web`, the portal backend
- writing the DNS records into `/etc/hosts` (and, on a cloud-init image,
  telling cloud-init to leave that file alone), bringing up the infra units
  (dnsmasq, the portal) and reconciling any enabled extra services (none
  by default — see
  [Extra services](#extra-services-mailpit-adminer-seleniumv1))
- **creating and starting the runtime container** `mpd-<NNN>-runtime` —
  the one container every project runs in
- a final DNS sanity check

(VM-side apt installs, the `mpd` build, and `/opt/mpd/bin/` on PATH all
happen earlier in the `bootstrap/20..30` steps and don't re-run here —
setup only verifies the packages are present and names
`bootstrap/20-install-software.sh` when one is missing; the network
stack and hostname are the platform bootstrap's job. See
`bootstrap/README.md`.)

Host-side trust + networking setup lives in the separate `mpd-virt`
orchestrator (own repo); see its README for the host-side flow.

## Hooking up your laptop (laptop-driven platforms only)

The container subnet is sealed from the LAN — only the laptop's overlay
or tunnel reaches in. Two host-side paths, both set up by `mpd-virt`:
the **mpd-proxy WireGuard overlay** (transparent, carries the whole
per-VM `/24`, every app, several VMs at once — needs sudo once) for
daily use, or the sudo-free **SOCKS-over-SSH** tunnel
(`ssh -N mpd-<NNN>-socks` + a dedicated browser) as the simple starting
point. Either way CA trust makes
`*.mpd.test` HTTPS work. Concrete network recipes (for the curious or for
recovery) live in [NETWORKING.md](NETWORKING.md).

The **sandbox platform has no laptop side** — mpd lives entirely
inside the VM, so there's no host route, no host resolver drop-in, and
no host CA trust to set up. Open Firefox inside the VM and browse to
`https://<NNN>.mpd.test/`.

## The VM's desktop, and reaching it from a tablet

An mpd VM boots headless. The desktop is there for the times a browser
has to run *inside* the VM — checking a project URL without the host-side
overlay, or a GUI you cannot drive over SSH.

```bash
gnome-install    # only on a VM that has no desktop at all: installs
                 # GNOME Shell, GDM, a terminal and Chromium, and
                 # nothing else. Points Chromium's home page at this
                 # VM's portal. Starts nothing; the boot target is left
                 # exactly as it was. ~320 MB. Idempotent.
gnome-start      # switch to the desktop now, and at every reboot
gnome-stop       # back to headless, now and at every reboot
```

`gnome-install` is for a VM that arrived without a desktop — a plain
Debian netinst with no task selected, or a server image. A sandbox VM and
a `mpd-virt`-provisioned VM already have GNOME; there `gnome-start` is
all you need. NetworkManager is deliberately left out (mpd runs the VM on
systemd-networkd), so GNOME's network panel is empty. Nothing else
notices.

**From an iPad or another device with no SSH tunnel:**

```bash
rdp-start        # installs xrdp, asks for a login password, opens tcp/3389
rdp-stop         # closes it again, now and at boot
```

`rdp-start` prompts for a password because it needs one: xrdp
authenticates through PAM, and the dev user of an mpd VM normally has no
password at all (SSH is pubkey-only, sudo is NOPASSWD). Having set it, the
tool turns SSH password authentication off — with a key already installed
— so the password buys RDP and nothing else. Connect to `<vm-ip>:3389` as
your usual username; the client will warn once about xrdp's self-signed
certificate.

**From an iPad.** Microsoft's Remote Desktop client (the "Windows App" on
the App Store) connects to `<vm-ip>:3389` and works well:

- Turn on **touch mode** in the in-session toolbar — a tap clicks where
  you touch, tap-and-hold is a right click, two fingers scroll. Without
  it your finger drives a trackpad instead, which is what people mean
  when they say the mouse feels wrong.
- **Set a screen size** in the connection's settings rather than
  accepting the tablet's native resolution. xorgxrdp creates whatever
  mode the client asks for, so the desktop arrives at a size you can
  actually use.
- A **keyboard with a trackpad** turns it into a workstation. GNOME is
  built around a pointer and behaves like itself once it has one.
- **Sessions survive disconnection.** xrdp reattaches to the existing X
  server, so the tablet can sleep or change network and you come back to
  the same desktop. To end one, log out inside GNOME — closing the app
  only detaches.

This is also the only way into an mpd VM from a tablet: iPadOS cannot do
the SOCKS or CA-trust setup the other paths need. See
[NETWORKING.md](NETWORKING.md#a-third-path-dont-reach-in-at-all).

Two things to know:

- **Log out of the console first.** GNOME does not run twice for the same
  user, so a session on the VM's console and an RDP session collide.
  `gnome-stop` is the tidy way.
- **This is the one mpd port held by a password**, not a key. Reach it
  over a hypervisor's host-only network, or a private network fronted by
  a bastion or a zero-trust tunnel — and run `rdp-stop` when you are
  done. [SECURITY.md](SECURITY.md) has the full reasoning.

## First project — Moodle

The tree comes from [mudev](https://github.com/mutms/mudev): it assembles a
Moodle branch plus a plugin set plus config from a recipe. Recipes resolve
from `/srv/extra/mdl-recipes/` by identifier (e.g. `moodle/release/4.5.12`)
or read from a path; run `mudev` with no arguments to list what is present
on this VM. Once the tree is in place, `mpd init` registers it as a project,
`mpd start` configures and brings it up, and `mdl-install` installs Moodle
itself.

Inside the VM:

```bash
# 1. Get the source. /srv is mounted on the VM, so this is ordinary shell —
#    a mudev recipe, or any git clone you like.
mkdir -p /srv/projects/moodle51 && cd /srv/projects/moodle51
mudev clone moodle/release/5.1.5
#    or: git clone -b MOODLE_501_STABLE https://github.com/moodle/moodle.git .

# 2. Scaffold (seeds mpd.env from the type's template; no DB yet).
#    No project name needed — it comes from the directory you are in.
mpd init --type=moodle

# 3. (optional) override defaults before the first start. Pass them to
#    start as KEY=VALUE, or edit /srv/projects/moodle51/mpd.env directly:
#      mpd start moodle51 MPD_DB=postgres:18
#      mpd start moodle51 MPD_PHP_VERSION=8.4
#    A legacy PHP an old branch needs (e.g. MPD_PHP_VERSION=7.4) is
#    fetched on demand at start — no extra step.

# 4. Start — one verb configures and brings it up: provisions the DB
#    container, creates the DB, writes config.php, publishes the URL.
#    (Install Moodle itself with `mdl-install` inside the runtime.)
mpd start moodle51
```

From your laptop, open `https://moodle51.<NNN>.mpd.test/`. Real cert (signed
by the local CA), no warnings.

**Outbound mail** is off by default — the generated config carries
`$CFG->noemailever = true` until you opt in to Mailpit, which is an
[extra service](#extra-services-mailpit-adminer-seleniumv1):

```bash
mpd --service-enable=mailpit
mpd start moodle51        # regenerate config-mpd.php → $CFG->smtphosts
```

The project then publishes an informational "mail" link —
`http://mailpit.svc.<NNN>.mpd.test:8025/?q=moodle51.<NNN>.mpd.test`, the
shared Mailpit inbox pre-filtered to this project.

**Behat**: set `MPD_MOODLE_BEHAT=1` and re-run `mpd start` —
that auto-enables the `seleniumv1` service, points `wd_host` at it, and
wires `https://behat.moodle51.<NNN>.mpd.test/` automatically.

Your own defaults (Moodle admin password, Behat preferences, etc.) live
in `/var/lib/mpd/env/mpd-virt.env` *inside the VM* and are bind-mounted
RO into the runtime container — write them once and the next command run
inside the runtime sees them. On a laptop-driven VM the file you actually
edit is `~/.mpd-virt/mpd-virt.env` on the Mac, which mpd-virt pushes into
every VM you run, so a preference set once follows you across all of
them; the in-VM copy is a mirror and is replaced on the next
`mpd-virt start`/`update`. A sandbox VM has no Mac behind it, so there
you edit the in-VM file directly.
The full layered
configuration model — file paths, sourcing order, reserved keys — is
documented in
[`ARCHITECTURE.md` §8](ARCHITECTURE.md#8-configuration-model-mpdenv).

## Extra services (mailpit, adminer, seleniumv1)

Nothing beyond the runtime is installed by default. Optional extras are
containers you enable by name:

```bash
mpd --service-enable=mailpit      # install + start + auto-start on boot
mpd --service-disable=mailpit     # stop; stays off across reboots
mpd --service-uninstall=mailpit   # remove the container, KEEP its data volume
mpd --service-purge=mailpit       # remove the container AND the volume
mpd list services                 # the three extras with their status
```

The three services and where they answer (HTTP only — their addresses
are inside the trust boundary, reached via the WireGuard overlay or the
SOCKS tunnel like everything else; no TLS, no proxying):

| Service      | URL                                        | Notes                                                        |
|--------------|--------------------------------------------|---------------------------------------------------------------|
| `mailpit`    | `http://mailpit.svc.<NNN>.mpd.test:8025/`  | Shared mail catch-all; SMTP on `:1025`. Data volume survives uninstall. |
| `adminer`    | `http://adminer.svc.<NNN>.mpd.test:8080/`  | DB web UI; the portal offers pre-filled per-project links.    |
| `seleniumv1` | `http://seleniumv1.svc.<NNN>.mpd.test:4444/` | Behat browser; auto-enabled by `mpd start` on a Behat-enabled Moodle project. |

Enabled services survive reboots (`mpd --vm-start` reconciles them) and
their enabled-set is visible to project `configure` scripts — which is
why toggling mailpit calls for a `mpd start <project>` re-run on
mail-aware projects.

## Running runtime commands from the VM

`mpd run` forwards a command into the runtime, so a one-off standing in
a project directory does not need an SSH hop:

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

This is where the AI-friendly part comes alive. The runtime container
has a real SSH endpoint. From your laptop, use the ProxyJump alias
`mpd-virt` wrote — the jump rides the VM's sshd, so it works with no
overlay or proxy running:

```bash
ssh -A mpd-<NNN>
```

Inside the VM the same alias works without the jump. Add `-A` only when
the session genuinely needs your SSH agent — see [SECURITY.md](SECURITY.md).

You land in the runtime as your local user (UID matched), with
passwordless sudo, agent-forwarded git auth, and the project tree at
`/srv/projects/<project>/`. From there:

- **VS Code Remote-SSH** → connect to `runtime.<NNN>.mpd.test`, open
  `/srv/projects/<project>/`. Language server, debugger, terminals
  all run inside the runtime.
- **PHPStorm Gateway** → same endpoint, same shape.
- **Claude Code over SSH** → `ssh -A user@runtime.<NNN>.mpd.test` and
  start a session inside the runtime. The agent reads/writes files,
  runs composer / phpunit / behat, pushes to GitHub via your
  forwarded agent key.

If you're inside the VM (e.g. a GNOME terminal in a desktop-in-VM
setup), use the VM-local SSH key instead of `-A`:

```bash
ssh mpd-<NNN>-runtime                # the alias mpd writes for you
ssh runtime                          # same thing, in-VM shorthand
ssh user@runtime.<NNN>.mpd.test      # the long form still works
```

All three use `~/.ssh/id_ed25519`, so no `-A` is needed. The alias is
a managed block `mpd --vm-setup` writes into the dev user's
`~/.ssh/config` — it fills in the user, points the alias at the real
name, and skips host-key verification, which a container that gets
rebuilt on demand would otherwise trip over on every rebuild.

The bare `runtime` resolves on the VM without any alias — `getent hosts
runtime` answers `10.163.<NNN>.2` — because mpd publishes it as a hosts
alias on the runtime's line in `/etc/hosts`. That matters for SSH clients
that offer a jump host but no `~/.ssh/config`: with ProxyJump the *jump
host* resolves the target through libc, never through an ssh alias, so an
app like Terminus can use jump = the VM, host = `runtime`. The ssh aliases
remain a convenience for `ssh`/`scp`/`rsync`; neither they nor the bare
name do anything in a browser, which needs the FQDN.

Anything you write *outside* the `# >>> mpd runtimes ... >>>` markers is
preserved across re-runs; anything inside them is regenerated.

`mpd-<NNN>-runtime` is also the runtime container's own hostname, but it
is not what the prompt shows: the shipped skel `.bashrc` rewrites bash's
`\h` to `mpd-<NNN>`, the alias the workstation uses to reach it, and the
VM's own prompt reads `mpd-<NNN>-vm` for the same reason. So a prompt
always tells you which of the two boxes you are on, in the same words
`ssh` takes on the laptop. Cosmetic only — `hostname`, `podman ps` and
DNS all still report the real names.

Both prompts also gain a `🔑 ` prefix when the session carries a
forwarded SSH agent, so whether `git push` can reach your laptop key is
something you see rather than something you remember about the `ssh`
command you typed (see [Pushing to git from inside the
runtime](#pushing-to-git-from-inside-the-runtime)).

`mpd --vm-setup` populates the runtime's `authorized_keys` with two key
sources: the laptop key (from the VM's `~/.ssh/authorized_keys`) and
the VM-local key (from `~/.ssh/id_*.pub`, generated by setup if
absent). On the sandbox platform the "laptop key" is just whatever
keys you have authorized for SSHing into the VM (or none, if you only
ever access the sandbox via the hypervisor's console).

The VM's own `authorized_keys` is only ever read, never written to —
setup creates it empty if missing and fixes its mode, nothing more. So
the two files differ by exactly one line, the VM's own key, and `cat
~/.ssh/authorized_keys` tells you which box you are on.

## `mpd` from inside the runtime

You don't need a second terminal to drive mpd. `mpd` is on `PATH` inside
the runtime and the project verbs work there:

```bash
ssh mpd-<NNN>
cd /srv/projects/newproject          # a directory that isn't a project yet
mpd init --type=moodle               # scaffolds it
mpd start newproject                 # configures + starts in one step
mpd status newproject
```

It is the same binary — `/opt/mpd` is bind-mounted read-only, so there is
no second build to keep in step. It notices it is inside a runtime, sends
the command to the VM over that runtime's control socket, and the VM runs
it. Because your terminal's own file descriptors are handed to the process
on the VM, output streams live and in colour, exit codes propagate into
`$?`, and a confirmation prompt like `mpd delete`'s reads your keystrokes.

**Most of mpd works here.** Project verbs (`init`, `start`, `stop`,
`reset`, `delete`, `status`, `help` — deletes included),
database management (`--db-*`), extra services (`--service-*`),
`--runtime-backup`, `--runtime-upgrade`, the read-only `--vm-status`,
and `list` all forward to the VM. A short denylist stays in a VM
terminal — the things that would terminate the runtime you're sitting in:
the VM lifecycle (`--vm-setup`/`--vm-upgrade`/`--vm-start`/`--vm-stop`/`--vm-restart`),
the runtime lifecycle (`--runtime-rebuild`, `--runtime-restore`), and the
control-plane daemons (`--web`, `--control`). `mpd run` is refused too:
you are already in the runtime, so run the command directly.

Two details worth knowing:

- **`--type` must exist.** A declared `--type` is checked against the
  types the assets tree defines (`moodle`, `astro`, `mdl-demo`); leave it out and
  mpd infers it exactly as on the VM (name match, else the `moodle`
  default).
- **`cd` where it matters.** Inside `/srv/projects/<name>/` the project
  name is inferred, exactly as on the VM. Elsewhere — including the
  `$HOME` you land in when you SSH in — name the project explicitly;
  `/srv` is the only tree that means the same thing on both sides.

To turn the whole thing off, set `MPD_RUNTIME_CONTROL=off` in
`/var/lib/mpd/env/mpd-virt.env`; it applies to the next command, no restart.
The trade-off it exists for is in
[`SECURITY.md`](SECURITY.md#the-runtime-control-socket).

### Pushing to git from inside the runtime

The runtime doesn't carry your private SSH key. Authenticate to
GitHub/GitLab/private remotes via **SSH agent forwarding** (`ssh -A`):

```bash
ssh-add ~/.ssh/id_ed25519           # load the key into your laptop's agent
                                    # (once per laptop session)
ssh -A user@runtime.<NNN>.mpd.test  # -A forwards the agent socket in
cd /srv/projects/moodle51
git push origin main                # forwarded agent signs; the remote
                                    # sees your laptop's key
```

A session with a forwarded agent shows a `🔑 ` on the prompt, so you
never have to reconstruct whether you passed `-A` — and `ssh-add -l`
inside the session is the live check that the agent still answers.

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

**Runtime tools (`assets/runtime/tools/`)** — available in any project.
Stack-independent ones first:

| Tool             | What it does                                                                                                                                                                                                                 |
|------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `claude-install` | Idempotent install of Claude Code (Anthropic's CLI) to `~/.local/bin/claude` via the upstream `curl \| bash` installer. Re-runs no-op.                                                                                       |
| `node-install`   | Idempotent install of nvm + Node.js (LTS by default) into `$HOME/.nvm/` (upstream-standard). After install, `nvm`/`node`/`npm` are on PATH for new login shells; `nvm install <ver>` then works without sudo. Re-runs no-op. |

**Runtime-level, same directory:**

| Tool               | What it does                                                                                                                                      |
|--------------------|---------------------------------------------------------------------------------------------------------------------------------------------------|
| `php`              | Project-aware PHP wrapper, registered as the Debian `php` alternative (so `/usr/bin/php` is it) — picks the project's `MPD_PHP_VERSION`, falls back to 8.2 outside a project tree. |
| `php-install`      | Install one PHP version on demand: `php-install 7.4`. The current versions are baked in; legacy EOL ones (7.4, 8.0) are not. `mpd start` calls this for you when a project's `MPD_PHP_VERSION` is not present, so you rarely run it by hand. Idempotent. |
| `composer`         | The Composer phar; installed at `/usr/local/bin/composer` by `composer-install` at provision time.                                                |
| `composer-install` | Idempotent install of Composer to `/usr/local/bin/`. Re-runs no-op.                                                                               |
| `composer-upgrade` | Force-reinstalls Composer (bypass idempotency). Use instead of `composer self-update` — the phar is root-owned and self-update can't write to it. |
| `mudev`            | Assembles a Moodle tree from a recipe. Built on the VM by `mpd --vm-setup` at `/opt/mudev`, bind-mounted read-only into the runtime, so the same binary answers on both sides. Its catalogues live in `/srv/extra/`. |

**Project-type-level (Moodle — `assets/runtime/project_types/moodle/tools/`):**

| Tool                                        | What it does                                                                                                                                                                                                                                                                                            |
|---------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `mdl-install`                               | Run `admin/cli/install_database.php` for the current project, with composer install + sensible defaults from `mpd.env`. Refuses if the project is unconfigured or already installed — checked before composer runs.                                                                                      |
| `mdl-cache-purge`                           | Run `admin/cli/purge_caches.php` for the current project.                                                                                                                                                                                                                                               |
| `mdl-cron`                                  | Run `admin/cli/cron.php` (one cycle) for the current project.                                                                                                                                                                                                                                           |
| `mdl-upgrade`                               | Run `admin/cli/upgrade.php --non-interactive` for the current project. Use after a git pull that updates code.                                                                                                                                                                                          |
| `mdl-data-backup` / `mdl-data-restore`      | Save and restore the current project's database + dataroot as one `.tgz` in the shared `/srv/backups/projects/` pile (restorable into any project). `mdl-data-restore --list` shows what is there. See [Backups](#backups).                                                                                                                 |
| `phpunit` / `phpunit-init` / `phpunit-util` | Run, initialize, and inspect Moodle's PHPUnit suite.                                                                                                                                                                                                                                                    |
| `behat` / `behat-init` / `behat-util`       | Run, initialize, and inspect Moodle's Behat suite.                                                                                                                                                                                                                                                      |
| `grunt`                                     | Wraps `npm install` + `grunt` for the current project's Moodle JS build.                                                                                                                                                                                                                                |
| `mpci` / `mpci-install`                     | Moodle Plugin CI runner and installer. The phar lives at `/srv/extra/mpci/` — on the data volume, so it survives `mpd --runtime-rebuild`. `rm` it and re-run `mpci-install` to pick up a newer release.                                                                                                          |

The `mdl-` prefix marks Moodle-specific operations whose bare name
would otherwise collide with system commands or be too generic
(`mdl-cron` vs system `cron`). Bare names match upstream tools
(`phpunit`, `behat`, `grunt`).

To throw a project's data away and start it again, there is no tool —
use the verb, [`mpd reset`](#starting-over-without-re-cloning-mpd-reset).
It works from inside the runtime too, and unlike a tool it can also stop
the project first, drop its DNS record, and mark it unconfigured.

**Project-type-level (Astro):** none, deliberately.

Astro ships its own commands and its own docs for them, so mpd adds
nothing: run `npm run dev`, `npm run build`, `npx @astrojs/upgrade`
exactly as astro.build describes. mpd does not run the dev server
either — `mpd start <project>` publishes the vhost, certificate and
DNS, and the URL starts answering the moment you start the server
yourself:

```bash
ssh runtime                       # or: ssh mpd-<NNN>-runtime from the host
cd /srv/projects/<project>
npm run dev                       # https://<project>.<NNN>.mpd.test/ is live
```

Astro 7.2+ can also run detached, which is usually what you want when
the terminal is doing something else:

```bash
npx astro dev --background        # same URL, no terminal held
npx astro dev status              # is one running, and where
npx astro dev logs --follow       # tail it
npx astro dev stop                # stop it
```

`astro preview` takes the same four. Astro selects background mode on
its own when it detects an AI agent driving the CLI — which inside an
mpd runtime is the common case.

`mpd start <project>` and `mpd stop <project>` print this rather than
doing it: they report whether a server is up (via `astro dev status`)
and which command you want. Neither starts or stops one, so an mpd verb
can never fight the server you started yourself.

caddy terminates TLS and reverse-proxies to `localhost:<port>`, where
`<port>` is `server.port` from `astro.config.mjs` (default 4321).
Change it there and re-run `mpd start <project>` so caddy follows.

Two details make the plain command work, both handled for you:

- The upstream is the name `localhost`, not `127.0.0.1`: a default
  `astro dev` listens on `[::1]` only, while `astro dev --host` listens
  on IPv4 only. A name lets either answer.
- `assets/runtime/project_types/astro/shellrc.sh` exports
  `__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS=.mpd.test`, without which
  Vite rejects the proxied `Host` header with "Blocked request. This
  host is not allowed."

**Project-type-level (mdl-demo): none either.**

An `mdl-demo` project is the source tree of
[mdl-demo](https://github.com/mutms/mdl-demo), the throwaway-Moodle
container. mpd publishes its front door and nothing more: `mpd start
<project>` writes two reverse-proxy URLs, `https://<project>.<NNN>.mpd.test`
(the management console) and `https://site.<project>.<NNN>.mpd.test` (the
demo site), with the certificate and DNS records to match. Both point at
fixed ports on the VM — 6381 and 6382 — which is where the project's own
`make run` puts its test container:

```bash
ssh mpd-<NNN>-vm                  # the VM, not the runtime: podman lives here
cd /srv/projects/<project>
make image                        # build the image
make run                          # start mpd-test-mdl-demo on 6381/6382
```

`make run` also tells the container its public URLs, so the console's
install form suggests the `site.` address. The container listens on the
VM's interfaces (the runtime's caddy reaches it at the bridge gateway),
which the host-only vmnet keeps private. One test container per VM —
`make run` replaces the previous one.

For trying mdl-demo's macOS launcher (or any other script written for
Apple `container`) on the VM, `/opt/mpd/bin/container` is a podman-backed
stand-in covering the everyday verbs (`run`, `start`, `stop`, `rm`,
`inspect`, `exec`, `logs`, `ls`).

## Backups

**Project backups** are `mdl-data-backup` / `mdl-data-restore`, two
Moodle tools you run from the project directory inside the runtime:

```bash
ssh mpd-<NNN>
cd /srv/projects/moodle45
mdl-data-backup before-upgrade     # or no name, for a UTC timestamp
mdl-data-restore --list
mdl-data-restore before-upgrade
```

One `.tgz` per backup in `/srv/backups/projects/`, holding the database,
the dataroot, the project's `mpd.env`, and a manifest recording the
database engine, the Moodle release and the PHP version. Every project's
backups share that one directory, so a bundle can be restored into any
project — name yours to tell them apart, and `mdl-data-restore --list`
shows which project each came from. It skips the
source tree (that is git's job), the PHPUnit and Behat dataroots
(`phpunit-init` / `behat-init` rebuild them), and Moodle's caches,
sessions and trash.

The site stays up throughout. Both tools write Moodle's CLI maintenance
file (`climaintenance.html`) into the dataroot for the duration, which
`lib/setup.php` checks before it opens a database connection — so the web
interface returns 503 while the dump or reload runs, and a maintenance
mode you set yourself is left alone. This is a development snapshot, not
a production backup: neither tool stops the project, and an `mdl-cron`
you start yourself can still write underneath it.

**Restore only ever writes**, so the project has to be empty first —
which is what [`mpd reset`](#starting-over-without-re-cloning-mpd-reset)
is for:

```bash
mpd reset          # drops the database, wipes the dataroot
mpd start      # makes an empty database to restore into
mdl-data-restore before-upgrade
```

Restoring over a project that still holds data is refused, with that
same recipe in the message. Destroying data belongs to `mpd reset`,
which also stops the project, tears down what the project type built and
drops the DNS record — none of which a tool inside the runtime can
reach. It is the same reason there is no `mdl-data-purge`.

Restore also refuses a bundle taken on a different database engine — a
PostgreSQL dump cannot load into MariaDB. A different Moodle release is
a warning rather than a refusal, and it tells you to run `mdl-upgrade`
afterwards. These same checks make a cross-project restore safe: it is
just a restore whose bundle happens to come from another project.

From your laptop, scp a bundle off the VM — `/srv` is mounted there:

```bash
scp mpd-<NNN>-vm:/srv/backups/projects/<name>.tgz ~/Downloads/
```

**Runtime backups** exist now and cover something different: the
developer's home directory inside the runtime container, which dies with
it. It is a deny-list — everything under `$HOME` except regenerable caches
and installed binaries — so config, dotfiles, IDE settings, SSH
`known_hosts` and shell history come back, but caches and binaries do not.
Binaries are left out on purpose: a rebuilt runtime gets fresh, current
tools, and reinstalling one (e.g. `claude-install`) is a single command,
so nothing stale is ever copied back in:

```bash
mpd --runtime-backup       # → /srv/backups/runtime/<UTC-timestamp>/ + manifest.json
mpd --runtime-rebuild      # fresh runtime from current assets
mpd --runtime-restore      # untars the newest backup into it
```

The work is asset-side — every `assets/runtime/backup.d/NN-*.sh`
(and `restore.d/` on the way back) runs inside the runtime as the dev
user with the backup directory as `$1`, so changing what is saved is
editing a script there, no Go change.

`/srv/backups/` is wiped when the data volume is wiped (`podman volume
rm`, VM reset, etc.). Always pull off before destructive ops you
care about.

## Starting over without re-cloning: `mpd reset`

`mpd reset <project>` throws away everything a project generated and puts
it back in the state `mpd init` left it in, **keeping the source tree**.
Two things it is for:

```bash
# The database is corrupted, or the data is not worth keeping.
mpd reset moodle45
mpd start moodle45            # reconfigures + starts: fresh, empty database
# then install Moodle again from the runtime: ssh mpd-<NNN>, mdl-install

# Switch database engine on an existing site.
mpd reset moodle45
vi /srv/projects/moodle45/mpd.env  # MPD_DB=postgres:18
mpd start moodle45            # config-mpd.php regenerated for the new engine, then started
```

**Kept:** `/srv/projects/<project>/` — the code, git history, `mpd.env`
and `config.php`. That is the point: nothing is re-cloned and no
hand-edited settings are lost. `config.php` is written only when missing,
while `config-mpd.php` (wwwroot, dataroot, DB credentials) is regenerated
on every `mpd start` — which is what lets the database change underneath
an unchanged `config.php`.

**Destroyed:** the project's database, everything inside
`/srv/data/<project>/` (dataroot plus the behat and phpunit ones), the
generated metadata in `/srv/meta/<project>/` including its TLS
certificate, and the project's DNS record.

**Left not configured.** Afterwards the project has no database, no
dataroot and no runtime assignment — the next `mpd start` reconfigures it
from `mpd.env` before bringing it up. That is also what makes the engine
switch work, since `start`'s configure step reads the new `MPD_DB`.

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
mpd --vm-diag                       # read-only health sweep; non-zero exit if anything failed

mpd --vm-upgrade                    # pull + rebuild mpd, then re-run --vm-setup (see below);
                                 # records the version it landed on, shown by --vm-diag
mpd --vm-start                      # reconcile current → requested (runtime, projects with state=running, enabled services)
mpd --vm-stop                       # graceful DB shutdown via EventMpdPreStop, then sudo systemctl poweroff
mpd --vm-restart                    # graceful stop, then sudo systemctl reboot; mpd auto-starts on boot

mpd list                         # list all projects (default)
mpd list services                # the optional extra services (mailpit, adminer, seleniumv1)
mpd list infra                   # infra: the runtime container, dnsmasq + the portal (systemd units)
mpd list dbs                     # list DB containers
mpd list network                 # this VM's addressing: id, zone, subnet, gateway

mpd status <project>             # show project info
mpd init <project> [...]         # scaffold a new project
mpd start <project> [K=V]        # apply mpd.env, configure + start (K=V, e.g. MPD_DB=postgres:18)
mpd stop <project>               # halt the project
mpd reset <project>              # destroy DB + data, keep the code (type the name to confirm)
mpd delete <project>             # remove the project entirely (type the name to confirm)
mpd help <project>               # all verbs for this project type

mpd --runtime-upgrade            # apt dist-upgrade + packages + re-configure, in place
mpd --runtime-rebuild            # delete + re-provision the runtime (prompts unless --yes),
                                 # restores running projects afterwards — only for a broken one
mpd --runtime-backup             # save runtime home-dir pieces to /srv/backups/runtime/
mpd --runtime-restore            # replay the newest runtime backup

mpd --service-enable=<name>      # install + start an extra service; auto-starts on boot
mpd --service-disable=<name>     # stop it; stays off until re-enabled
mpd --service-uninstall=<name>   # remove the container, keep its data volume
mpd --service-purge=<name>       # remove the container AND the volume

mpd --help                       # full flag reference
```

VM-side tools, not `mpd` verbs — they act on the VM itself, not on a
project (see "The VM's desktop, and reaching it from a tablet"):

```bash
gnome-install                    # minimal GNOME + Chromium, on a VM with no desktop
gnome-start / gnome-stop         # desktop on / off, persistent across reboots
rdp-start / rdp-stop             # open / close RDP on tcp/3389 (opt-in, password-authenticated)
claude-install                   # Claude Code on the VM itself (same script the runtime ships)
```

## Updating mpd

```bash
mpd --vm-upgrade
```

Pulls the `/opt/mpd` checkout forward, rebuilds the binary, updates the
mudev checkout and the `/srv/extra` catalogues, then re-runs
`mpd --vm-setup` and `mpd --runtime-upgrade` with the new binary — the
steps a bare `git pull && make install` would miss, since asset scripts,
systemd units and the resolver's config only reach the VM through
setup, and the runtime container is upgraded in place (apt + re-configure)
rather than rebuilt. Refuses if `/opt/mpd`
has uncommitted changes (commit, stash or discard first). Idempotent —
an up-to-date VM just gets a rebuild and a fresh setup pass. A checkout
you have re-pointed at your own remote is left alone and reported.

It does not touch apt. To bring the operating system and the package
set forward too, run the bootstrap install step first — it is
idempotent, and `mpd-virt update <NNN>` runs exactly this pair:

```bash
bash /opt/mpd/bootstrap/20-install-software.sh   # apt dist-upgrade + the package set
mpd --vm-upgrade
```

Neither `--vm-upgrade` nor `--vm-setup` migrates a VM across a change in
mpd's own in-VM layout; they assume a VM that never had the old one. When
such a change lands, the repo ships a one-shot script under `bin/` to run
by hand on each existing VM — currently `migrate-vm-network.sh`, which
moves a VM set up before DNS records lived in `/etc/hosts`. Everyone else
creates new VMs.

## When you want to start over

A few flavors, increasing severity:

```bash
# Rebuild the runtime container from current assets. Keeps projects + DBs
# (the data volume keeps /srv/projects, /srv/dbs) and restores running
# projects afterwards; only the container's home directory is lost —
# `mpd --runtime-backup` first, `mpd --runtime-restore` after, carries
# the pieces worth keeping.
mpd --runtime-backup
mpd --runtime-rebuild
mpd --runtime-restore

# Container-layer reset. The first thing to try after upgrading mpd across
# changes that alter container shape — new mounts, labels, images, or a
# service that moved out of a container entirely. Everything mpd creates is
# rebuilt from scratch; nothing you made is touched, because projects, DB
# data and mpd state live outside the containers.
sudo podman rm -af               # every mpd container, running or not
sudo podman network rm mpd-internal

mpd --vm-setup                   # network + infra + units, from scratch —
                                 # including the runtime container, which setup
                                 # creates (restoring running projects), and any
                                 # enabled extra services
mpd start <project>              # per project still missing. Recreates the
                                 # project's DB container on demand; its data
                                 # survived in /srv/dbs/<id>/, so the databases
                                 # come back with the container

# Manual in-VM reset (no --uninstall verb on mpd):
rm -rf /var/lib/mpd                    # blow away state + identity in the VM

# Delete the VM itself: hypervisor's VM-delete operation (or, for sandbox,
# revert to your pre-take-over snapshot), then re-bootstrap from any
# setup/<name>/. On macOS hosts: `mpd-virt uninstall` (separate
# orchestrator binary, own repo) handles the host side cleanly.
```

## Reference

- [README.md](README.md) — documentation index (audience-shaped)
- [../README.md](../README.md) — top-level pitch + mode picker + first bootstrap
- [NETWORKING.md](NETWORKING.md) — host ↔ VM ↔ container routing
- [SECURITY.md](SECURITY.md) — trust boundaries
