# Usage

Operational handbook for `mpd`: bootstrap, first project, day-to-day.
Applies to **both Sandbox VM and mpd VM modes** — the CLI surface is
identical once `mpd --vm-setup` has run. Mode-specific notes are called
out where they matter.

## Bootstrap (one-time)

You need a Debian Trixie VM with `mpd` built and reachable over SSH.
Pick the path that matches your host:

- **macOS or Linux host (automated)** — Parallels / UTM / Apple
  container on macOS, libvirt/KVM on Linux, Proxmox or any cloud/bare
  Debian VM from either:
  [`mpd-virt`](https://github.com/mutms/mpd-virt) (separate repo).
  `mpd-virt adopt <NNN> <IP>` adopts any reachable Debian Trixie VM:
  it runs the bootstrap pipeline over SSH, installs `mpd`, and wires host
  reachability — the **mpd-proxy WireGuard overlay** for daily transparent
  access, or a **SOCKS-over-SSH** fallback (`ssh -N mpd-<NNN>-socks`) that
  needs no sudo. `mpd-virt remove` / `uninstall` un-adopt and tear the host side down; VM power
  (where the backend supports it) via `mpd-virt start|stop` or the
  hypervisor's GUI.
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
- installing and configuring the apex caddy, which serves the portal at
  `https://<NNN>.mpd.test/` on the gateway `.1`
- starting `mpd --web`, the portal backend
- writing the DNS records into `/etc/hosts` (and, on a cloud-init image,
  telling cloud-init to leave that file alone), bringing up the infra units
  (dnsmasq, the portal) and reconciling any enabled extra services (none
  by default — see
  [Extra services](#extra-services-mailpit-adminer-selenium))
- **installing and configuring the dev stack** — the PHP matrix and its
  FPM pools, the `php` dispatcher, Composer, Node
- **starting the project frontdoor** `mpd-caddy.service`, which serves
  every project vhost on `10.163.<NNN>.2` — see
  [networking.md](networking.md)
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
recovery) live in [networking.md](networking.md).

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

## Nested VMs: testing mpd-virt from inside an mpd VM

```bash
libvirt-install  # make this VM a libvirt/KVM host: qemu + libvirt,
                 # the `default` NAT network, /var/lib/mpd-virt, KVM
                 # nested=1; clones mpd-virt to ~/Developer/mpd-virt
                 # and `make install`s it (~/.local/bin/mpd-virt), and
                 # clones mpd-proxy to ~/Developer/mpd-proxy unbuilt.
                 # Idempotent.
mpd-virt create 150 --backend=libvirt   # a nested mpd VM at 192.168.122.150
```

Needs nested virtualisation from the outer hypervisor (Proxmox: CPU type
`host`; Parallels/UTM: the nested-virtualisation switch) — the script
checks for VMX/SVM and `/dev/kvm` and refuses without them. Log in again
after the first run if it added you to the `libvirt` group. The rest of
the libvirt backend (reaching the nested VM, its files, limits) is in
mpd-virt's `docs/LIBVIRT.md`.

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
[networking.md](networking.md#a-third-path-dont-reach-in-at-all).

Two things to know:

- **Log out of the console first.** GNOME does not run twice for the same
  user, so a session on the VM's console and an RDP session collide.
  `gnome-stop` is the tidy way.
- **This is the one mpd port held by a password**, not a key. Reach it
  over a hypervisor's host-only network, or a private network fronted by
  a bastion or a zero-trust tunnel — and run `rdp-stop` when you are
  done. [security.md](security.md) has the full reasoning.

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
#    (Install Moodle itself with `mdl-install`.)
mpd start moodle51
```

From your laptop, open `https://moodle51.<NNN>.mpd.test/`. Real cert (signed
by the local CA), no warnings.

**Outbound mail** is off by default — the generated config carries
`$CFG->noemailever = true` until this project declares it needs
[Mailpit](#extra-services-mailpit-adminer-selenium) in its `mpd.env`:

```bash
mpd start moodle51 MPD_REQUIRE_SERVICES=mailpit
```

That one command records the requirement, starts the Mailpit container the way
a database is ensured, and regenerates `config-mpd.php` with
`$CFG->smtphosts` pointing at it. Mail routing is thus a property of the
project (tracked in git), and `noemailever` stays the safe default for any
project that has not opted in. The project also publishes an informational
"mail" link — `http://mailpit.svc.<NNN>.mpd.test:8025/?q=moodle51.<NNN>.mpd.test`,
the shared Mailpit inbox pre-filtered to this project.

**Behat**: set `MPD_MOODLE_BEHAT=1` and re-run `mpd start` — that adds
`selenium` to the project's required services (starting it on your behalf),
points `wd_host` at it, and wires `https://behat.moodle51.<NNN>.mpd.test/`
automatically.

Your own environment — a Moodle admin password `mdl-install` reads,
`MPD_MOODLE_AGREE_LICENSE`, an API token — lives in
`/var/lib/mpd/env/vm.env` *inside the VM*, sourced into every shell:
write it once and the next command sees it. (This is ambient environment,
not an `mpd.env` layer — for a key a project type already defaults, like
`MPD_MOODLE_BEHAT`, override it per project in that project's `mpd.env`;
see [`architecture.md` §8](architecture.md).) On a laptop-driven VM the
file you actually edit is `~/.mpd-virt/vm.env` on the Mac, which mpd-virt
pushes into every VM you run, so a setting made once follows you across
all of them; the in-VM copy is a mirror and is replaced on the next
`mpd-virt adopt`/`update`. A sandbox VM has no Mac behind it, so there you
edit the in-VM file directly.
The full layered
configuration model — file paths, sourcing order, reserved keys — is
documented in
[`architecture.md` §8](architecture.md#8-configuration-model-mpdenv).

## Extra services (mailpit, adminer, selenium)

No extra service is installed by default. The usual way one
comes up is a project declaring it in `MPD_REQUIRE_SERVICES` (above): mpd then
starts it on demand, the way it ensures a project's database. The flags below
are for driving a service directly — one you want up on its own, independent of
any project:

```bash
mpd --service-start=mailpit       # start it + keep it autostarting on boot
mpd --service-stop=mailpit        # stop it + clear autostart (a project that needs it restarts it)
mpd --service-uninstall=mailpit   # remove the container, KEEP its data volume
mpd --service-purge=mailpit       # remove the container AND the volume
mpd list services                 # the three extras with their status
```

Lifecycle mirrors databases: a service a project requires is started when that
project starts (no sticky flag), while `--service-start`/`--service-stop` set a
sticky autostart intent that `mpd --vm-start` reconciles at boot. A
`--service-stop` cannot hold down a service a running project requires — the
next `mpd start` ensures it again, just like a stopped database.

The three services and where they answer (HTTP only — their addresses
are inside the trust boundary, reached via the WireGuard overlay or the
SOCKS tunnel like everything else; no TLS, no proxying):

| Service      | URL                                          | Notes                                                                         |
|--------------|----------------------------------------------|-------------------------------------------------------------------------------|
| `mailpit`    | `http://mailpit.svc.<NNN>.mpd.test:8025/`    | Shared mail catch-all; SMTP on `:1025`. Data volume survives uninstall.       |
| `adminer`    | `http://adminer.svc.<NNN>.mpd.test:8080/`    | DB web UI; the portal offers pre-filled per-project links.                    |
| `selenium` | `http://selenium.svc.<NNN>.mpd.test:4444/` | Behat browser; started by `mpd start` on a Behat-enabled Moodle project. |

Autostart services survive reboots (`mpd --vm-start` reconciles them);
required services come back when their project starts. Because a project's
config is rendered from its own `MPD_REQUIRE_SERVICES`, changing that list
takes effect on the next `mpd start <project>`.

## SSH into the VM

This is where the AI-friendly part comes alive. From your laptop, use the
alias `mpd-virt` wrote:

```bash
ssh mpd-<NNN>
```

It goes straight to the VM's sshd — no jump host, no overlay, no proxy.
Add `-A` only when you need your SSH agent in that session, and never in
a session where an AI agent works — see [security.md](security.md).

You land as the dev user, with passwordless sudo, every tool on PATH and
the project tree at `/srv/projects/<project>/`. From there:

- **VS Code Remote-SSH** → connect to `mpd-<NNN>`, open
  `/srv/projects/<project>/`. Language server, debugger and terminals all
  run on the VM.
- **PHPStorm Gateway** → same endpoint, same shape.
- **Claude Code over SSH** → `ssh mpd-<NNN>` (no `-A`). The agent
  reads/writes files and runs composer / phpunit / behat. It has no key,
  so it cannot push: commit and push from the host (PhpStorm or a host
  terminal) yourself.

Anything you write *outside* mpd-virt's `# >>> mpd-<NNN> ... >>>` markers
in `~/.ssh/config` is preserved across re-runs; anything inside them is
regenerated.

The prompt gains a `🔑 ` prefix when the session carries a forwarded SSH
agent, so whether `git push` can reach your laptop key is something you
see rather than something you remember about the `ssh` command you typed
(see [Pushing to git](#pushing-to-git-from-the-vm)).


### Pushing to git from the VM

The VM doesn't carry your private SSH key. The simple way is to not push
from there at all: the IDE on the host (PhpStorm, VS Code) commits and
pushes with the host's key, and an AI agent on the VM never gets one. For
a session where you type yourself, **SSH agent forwarding** (`ssh -A`)
works:

```bash
ssh-add ~/.ssh/id_ed25519           # load the key into your laptop's agent
                                    # (once per laptop session)
ssh -A mpd-<NNN>                    # -A forwards the agent socket in
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
forwarded socket and can push as you — so do not start one there.

The private key **never leaves the laptop**. The VM can request
signatures via the agent's API only while your SSH session is open —
there's no way to extract the key. Close the session, auth goes away.
Wipe or compromise the VM, your key is unaffected.

**One more guard.** Agent forwarding lets the AI push commits *under
your identity* — so the consequence-blocking moves to the remote, not
the VM. Minimum recommended: **block force-pushes on protected
branches** (`main`, release branches) under *GitHub Settings →
Branches*. Every change the AI makes lands as an append-only commit
you can audit. Stricter shops also require PRs for `main`.

### Tools available in the VM

The following tools are on PATH — project-aware (cwd-walk to find the
current project) and ready for either a human or an AI agent to invoke
directly. Full taxonomy in
[`architecture.md` §7](architecture.md).

**VM tools (`assets/vm/bin/`)** — available in any project.
Stack-independent ones first:

| Tool             | What it does                                                                                                                                                                                                                 |
|------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `claude-install` | Idempotent install of Claude Code (Anthropic's CLI) to `~/.local/bin/claude` via the upstream `curl \| bash` installer. Re-runs no-op.                                                                                       |
| `node-install`   | Idempotent install of nvm + Node.js (LTS by default) into `$HOME/.nvm/` (upstream-standard). After install, `nvm`/`node`/`npm` are on PATH for new login shells; `nvm install <ver>` then works without sudo. Re-runs no-op. |
| `phpstorm-archive-app` | Pack this VM's Toolbox-installed PhpStorm backend into `~/install/phpstorm.tgz`, and print the `scp` line that seeds it into every future VM through your mpd-virt overlay.                                        |
| `phpstorm-install-app` | Unpack `/opt/mpd/assets/jetbrains/phpstorm.tgz` (or `~/install/phpstorm.tgz`) into the Toolbox apps directory, so a fresh VM skips the three-gigabyte backend download. No-ops when PhpStorm is already there or neither tarball is. |

**Same directory, the PHP stack:**

| Tool               | What it does                                                                                                                                      |
|--------------------|---------------------------------------------------------------------------------------------------------------------------------------------------|
| `php`              | Project-aware PHP wrapper, registered as the Debian `php` alternative (so `/usr/bin/php` is it) — picks the project's `MPD_PHP_VERSION`, falls back to 8.3 outside a project tree. |
| `php-install`      | Install one PHP version on demand: `php-install 7.4`. `--vm-setup` installs 8.1–8.5; legacy EOL ones (7.4, 8.0) are not. `mpd start` calls this for you when a project's `MPD_PHP_VERSION` is not present, so you rarely run it by hand. Idempotent. |
| `composer`         | The Composer phar; installed at `/usr/local/bin/composer` by `composer-install` at provision time.                                                |
| `composer-install` | Idempotent install of Composer to `/usr/local/bin/`. Re-runs no-op.                                                                               |
| `composer-upgrade` | Force-reinstalls Composer (bypass idempotency). Use instead of `composer self-update` — the phar is root-owned and self-update can't write to it. |
| `mudev`            | Assembles a Moodle tree from a recipe. Built at `/opt/mudev`. Its catalogues live in `/srv/extra/`. |

**Project-type-level (Moodle — `assets/vm/project_types/moodle/bin/`):**

| Tool                                        | What it does                                                                                                                                                                                                                |
|---------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `mdl-install`                               | Run `admin/cli/install_database.php` for the current project, with composer install + sensible defaults from `mpd.env`. Refuses if the project is unconfigured or already installed — checked before composer runs.         |
| `mdl-cache-purge`                           | Run `admin/cli/purge_caches.php` for the current project.                                                                                                                                                                   |
| `mdl-cron`                                  | Run `admin/cli/cron.php` (one cycle) for the current project.                                                                                                                                                               |
| `mdl-upgrade`                               | Run `admin/cli/upgrade.php --non-interactive` for the current project. Use after a git pull that updates code.                                                                                                              |
| `mdl-data-backup` / `mdl-data-restore`      | Save and restore the current project's database + dataroot as one `.tgz` in the shared `/srv/backups/projects/` pile (restorable into any project). `mdl-data-restore --list` shows what is there. See [Backups](#backups). |
| `phpunit` / `phpunit-init` / `phpunit-util` | Run, initialize, and inspect Moodle's PHPUnit suite.                                                                                                                                                                        |
| `behat` / `behat-init` / `behat-util`       | Run, initialize, and inspect Moodle's Behat suite.                                                                                                                                                                          |
| `grunt`                                     | Wraps `npm install` + `grunt` for the current project's Moodle JS build.                                                                                                                                                    |
| `mpci` / `mpci-install`                     | Moodle Plugin CI runner and installer. The phar lives at `/srv/extra/mpci/`, on the data volume. `rm` it and re-run `mpci-install` to pick up a newer release.                     |

The `mdl-` prefix marks Moodle-specific operations whose bare name
would otherwise collide with system commands or be too generic
(`mdl-cron` vs system `cron`). Bare names match upstream tools
(`phpunit`, `behat`, `grunt`).

To throw a project's data away and start it again, there is no tool —
use the verb, [`mpd reset`](#starting-over-without-re-cloning-mpd-reset).
Unlike a tool it can also stop the project first, drop its DNS record,
and mark it unconfigured.

**Project-type-level (Astro):** none, deliberately.

Astro ships its own commands and its own docs for them, so mpd adds
nothing: run `npm run dev`, `npm run build`, `npx @astrojs/upgrade`
exactly as astro.build describes. mpd does not run the dev server
either — `mpd start <project>` publishes the vhost, certificate and
DNS, and the URL starts answering the moment you start the server
yourself:

```bash
ssh mpd-<NNN>
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
its own when it detects an AI agent driving the CLI — which on an mpd VM
is the common case.

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
- `assets/vm/project_types/astro/shellrc.sh` exports
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
ssh mpd-<NNN>
cd /srv/projects/<project>
make image                        # build the image
make run                          # start mpd-test-mdl-demo on 6381/6382
```

`make run` also tells the container its public URLs, so the console's
install form suggests the `site.` address. The container listens on the
VM's interfaces, which the host-only vmnet keeps private. One test container per VM —
`make run` replaces the previous one.

For trying mdl-demo's macOS launcher (or any other script written for
Apple `container`) on the VM, `/opt/mpd/assets/vm/bin/container` is a podman-backed
stand-in covering the everyday verbs (`run`, `start`, `stop`, `rm`,
`inspect`, `exec`, `logs`, `ls`).

## Backups

**Project backups** are `mdl-data-backup` / `mdl-data-restore`, two
Moodle tools you run from the project directory:

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
drops the DNS record — none of which a tool can
reach. It is the same reason there is no `mdl-data-purge`.

Restore also refuses a bundle taken on a different database engine — a
PostgreSQL dump cannot load into MariaDB. A different Moodle release is
a warning rather than a refusal, and it tells you to run `mdl-upgrade`
afterwards. These same checks make a cross-project restore safe: it is
just a restore whose bundle happens to come from another project.

From your laptop, scp a bundle off the VM — `/srv` is mounted there:

```bash
scp mpd-<NNN>:/srv/backups/projects/<name>.tgz ~/Downloads/
```

Your dev environment needs no backup of its own. The home directory
lives on the VM, so nothing short of deleting the VM destroys it, and a
hypervisor snapshot protects it — installed tools and IDE backends
included.

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
# then install Moodle again: ssh mpd-<NNN>, mdl-install

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
dataroot and marked unconfigured — the next `mpd start` reconfigures it
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
mpd --vm-start                      # reconcile current → requested (projects with state=running, enabled services)
mpd --vm-stop                       # graceful DB shutdown via EventMpdPreStop, then sudo systemctl poweroff
mpd --vm-restart                    # graceful stop, then sudo systemctl reboot; mpd auto-starts on boot

mpd list                         # list all projects (default)
mpd list services                # the optional extra services (mailpit, adminer, selenium)
mpd list infra                   # infra: dnsmasq, the portal, the project frontdoor
mpd list dbs                     # list DB containers
mpd list network                 # this VM's addressing: id, zone, subnet, gateway

mpd status <project>             # show project info
mpd init <project> [...]         # scaffold a new project
mpd start <project> [K=V]        # apply mpd.env, configure + start (K=V, e.g. MPD_DB=postgres:18)
mpd stop <project>               # halt the project
mpd reset <project>              # destroy DB + data, keep the code (type the name to confirm)
mpd delete <project>             # remove the project entirely (type the name to confirm)
mpd help <project>               # all verbs for this project type

mpd --service-start=<name>       # start an extra service + keep it autostarting on boot
mpd --service-stop=<name>        # stop it + clear autostart (a project that needs it restarts it)
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
claude-install                   # Claude Code on the VM
goland-archive-app               # pack this VM's Toolbox GoLand into ~/install/goland.tgz
goland-install-app               # unpack that tarball on a new VM instead of downloading GoLand
```

`goland-archive-app` / `goland-install-app` are the fast path for the
in-VM IDE. Archive once on a VM that has GoLand, copy the tarball to
`~/.mpd-virt/assets/jetbrains/` on your workstation, and every VM
mpd-virt adopts or creates from then on reads it at
`/opt/mpd/assets/jetbrains/goland.tgz` — `goland-install-app` unpacks it
in seconds. The archive stays in the assets tree; it is never copied into
a home. Both no-op when there is nothing to do.

## Updating mpd

```bash
mpd --vm-upgrade
```

Pulls the `/opt/mpd` checkout forward, rebuilds the binary, updates the
mudev checkout and the `/srv/extra` catalogues, then re-runs
`mpd --vm-setup` with the new binary — the steps a bare
`git pull && make install` would miss, since asset scripts, systemd
units and the resolver's config only reach the VM through setup.
Refuses if `/opt/mpd`
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
mpd's own in-VM layout. After such a change, create new VMs.

## When you want to start over

A few flavors, increasing severity:

```bash
# Re-converge the dev stack. Re-installs anything missing from the PHP
# matrix, rewrites the FPM pools and the caddy unit, and re-applies the
# php dispatcher. Safe at any time.
mpd --vm-setup

# Container-layer reset. The first thing to try after upgrading mpd across
# changes that alter container shape — new mounts, labels, images, or a
# service that moved out of a container entirely. Everything mpd creates is
# rebuilt from scratch; nothing you made is touched, because projects, DB
# data and mpd state live outside the containers.
sudo podman rm -af               # every mpd container, running or not
sudo podman network rm mpd-internal

mpd --vm-setup                   # network + infra + units, from scratch,
                                 # including any enabled extra services
mpd start <project>              # per project still missing. Recreates the
                                 # project's DB container on demand; its data
                                 # survived in /srv/dbs/<id>/, so the databases
                                 # come back with the container

# Manual in-VM reset (no --uninstall verb on mpd):
rm -rf /var/lib/mpd                    # blow away state + identity in the VM

# Delete the VM itself: hypervisor's VM-delete operation (or, for sandbox,
# revert to your pre-take-over snapshot), then re-bootstrap. On the
# host: `mpd-virt remove` / `mpd-virt uninstall` (separate orchestrator
# binary, own repo) handle the host side cleanly.
```

## Reference

- [README.md](README.md) — documentation index (audience-shaped)
- [../README.md](../README.md) — top-level pitch + mode picker + first bootstrap
- [networking.md](networking.md) — host ↔ VM ↔ container routing
- [security.md](security.md) — trust boundaries
