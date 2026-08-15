# AI Agent Starting Point

Neutral bootstrap document for AI agents working in this repository. Single
source of truth; `CLAUDE.md` imports this file via `@AGENTS.md` so Claude
Code, Codex, Aider, and other tools that read AGENTS.md natively all see
the same instructions.

## What mpd is

`mpd` (Moodle Plugin Development) is a local development environment for
Moodle plugin work, built around a reproducible runtime container, local DNS,
and HTTPS endpoints. It has two user-facing modes, distinguished by where
the user sits and where `mpd` runs:

- **Sandbox VM** — full GNOME desktop *inside* the VM, `mpd` runs in
  the VM. User installs Debian Trixie desktop in any hypervisor,
  snapshots, runs `setup/mpd-sandbox-setup.sh` inside the
  VM. Host stays untouched.
- **mpd VM** — automated Debian Trixie VM driven by a matched-host
  bootstrap (Parallels Desktop Pro / UTM on macOS via `mpd-virt` —
  primary; libvirt/KVM on Ubuntu and Hyper-V on Windows are automated
  in-repo but less exercised). Defaults to
  headless; GNOME is installed and toggleable on demand via
  `gnome-start` / `gnome-stop` (persistent across reboots). User stays
  on their host: host browser visits `*.<NNN>.mpd.test` directly via
  the mpd-proxy WireGuard overlay or a SOCKS-over-SSH tunnel + CA
  trust; host terminal SSHes into the VM to use the `mpd` CLI.

`mpd` itself is a single Linux binary that runs **inside the VM**. The
macOS-host orchestrator (`mpd-virt`) that drives Parallels lives in a
separate repository.

**Implementation note:** a sandbox and a managed VM are the *same* thing
at runtime — same code paths, same hostname-derived identity (mpd-<NNN>,
via `net.Current`). They differ only in *setup*: a sandbox generates its
own self-signed CA in the VM, a managed VM gets a CA pushed by the
host-side `mpd-virt`. A sandbox can be adopted as a managed VM later with
no runtime change.

`README.md` is deliberately terse; this file carries the depth. The
background below is the long-form context that used to live there — keep it
here, not in README.

## Background and positioning

**Why mpd exists.** It grew out of a personal security stance plus a working
pattern: the owner uses AI agents (Claude Code, Codex) to build and maintain
Moodle plugins and wants them inside a sandbox — no Homebrew, MacPorts, Node,
PHP, or Apache on the laptop, and no AI agent loose on it either. mpd's
predecessor ([MDC](https://github.com/skodak/mdc)) automated OrbStack, but
OrbStack is closed-source — for a tool that decides what your browser trusts,
the trust-deciding code should be readable. mpd lives entirely in this repo:
Go control plane plus shell tooling on top of Podman, with a name-constrained
local CA that can only sign for `*.mpd.test`. The Sandbox VM is the
recommended starting point — a whole hypervisor between dev work and host,
with snapshot/revert as the safety net for letting an agent rip.

**What it gives, day to day:**

- `https://<project>.<NNN>.mpd.test/` for every project — browser-trusted
  HTTPS via the name-constrained local CA, live the moment
  `mpd start <project>` returns. `<NNN>` is the VM's id, so several VMs
  coexist without name collisions (see `docs/NETWORKING.md`).
- Per-project PHP version (`MPD_PHP_VERSION=8.4` on one project, `8.2` on the
  next, simultaneously) and per-project database (`MPD_DB=postgres:18` —
  `<engine>:<version>`, not a port; provisioned on demand, no shared DB
  server with table prefixes).
- One-verb reset: `mpd reset <project>` drops the DB, wipes the dataroots and
  clears the generated state — keeps the source tree, `mpd.env` and
  `config.php`. Works from a VM terminal or from inside the runtime.
- Optional per-VM services (`mpd --service-enable=<name>`; nothing installed
  by default): Mailpit (`http://mailpit.svc.<NNN>.mpd.test:8025/` — one shared
  inbox, each project publishing a pre-filtered link), Adminer, Selenium.
  Behat is auto-wired when a project asks: `MPD_MOODLE_BEHAT=1` makes
  `mpd configure` enable the seleniumv1 service and publish
  `https://behat.<project>.<NNN>.mpd.test/`.
- No host pollution: no Homebrew PHP, no system Apache, no `brew upgrade`
  breakage.

**The IDE/agent workflow.** The IDE (VS Code Remote-SSH, PhpStorm Gateway)
connects to the runtime container over SSH — the IDE process stays on the
host; language server, Xdebug, and terminal execute inside. The AI agent is
installed inside the runtime (`claude-install`) and runs as a process in the
container, sharing the same files and tools the IDE edits. SSH is the clean
integration point — no filesystem-mount layer papering over the network.
(When the work is on mpd itself — Go sources, asset scripts — the agent runs
in the VM instead, where the checkout and toolchain live.)

**Coming from other tooling:** vs. Homebrew-native PHP+MariaDB — per-project
containers instead of a shared stack; tradeoff is a few seconds of container
startup vs. millisecond-fast native invocation. Vs.
[moodle-docker](https://github.com/moodlehq/moodle-docker) — same
daily-driver pattern plus per-project URLs with real HTTPS, one-command
Mailpit, automatic Behat/Selenium wiring, the SSH-into-runtime endpoint, and
the VM boundary. Vs. [DDEV](https://ddev.com/) / [Lando](https://lando.dev/)
— the Moodle-specific cousin of the same per-project-URL + auto-TLS
philosophy, hardened with a VM boundary and shaped around AI agents as a
first-class consumer.

**Both modes ship GNOME.** Sandbox boots into it; mpd VM defaults to headless
but GNOME is installed and toggleable — `gnome-start` brings the desktop up
(and pins it as the boot target until you flip back), `gnome-stop` returns to
headless. Useful for an occasional in-VM Firefox session or GUI debugging.

**Timing expectations:** first-time VM bootstrap 5–15 min (image download,
apt, Go toolchain, build); first `mpd --vm-setup` (includes the runtime
build) 3–5 min;
subsequent `mpd start <project>` a few seconds; `demo <recipe> <name>` a few
minutes the first time, near-instant on re-runs; VM resume from suspend,
seconds.

**Top-level repo layout:** `bin/` (built `bin/mpd` plus committed VM tools:
`demo`, `claude-install`, `gnome-start`/`gnome-stop`), `go/` (control plane),
`assets/` (runtime/service definitions and shell), `bootstrap/`
(VM bring-up steps), `setup/` (per-platform host orchestration), `docs/`.
Runtime state lives at `/var/lib/mpd/` (see Fixed in-VM paths below).

## Fixed in-VM paths

mpd has three absolute, VM-wide paths. All owned by the dev user (bootstrap
chowns), all enforced at runtime — do not propose alternates.

- `/opt/mpd/` — the git checkout: code, assets, built binary (`/opt/mpd/bin/mpd`).
  FHS slot for add-on packages. Bind-mounted RO into every mpd-created
  container at the same path, so `/opt/mpd/assets/...` resolves identically
  on the VM and inside containers.
- `/var/lib/mpd/conf/` — persistent identity. Trust anchor + this VM's
  own signing CA + service cert. PRIVATE — never bind-mounted into
  containers.
- `/var/lib/mpd/env/` — the developer's own env overrides, shared across
  every VM they run. Holds `mpd-virt.env` only, pushed in from the Mac's
  `~/.mpd-virt/mpd-virt.env` by mpd-virt (hand-edited in-VM on a sandbox).
  Bind-mounted RO into every runtime container at the same path
  (directory mount, so vim/nano atomic-rename writes propagate).
- `/var/lib/mpd/skel/` — user-managed dotfile overrides for the runtime
  container. Same idea as `/etc/skel/`: contents are copied into
  `/home/<user>/` at runtime create, layered on top of the shipped
  `assets/runtime/skel/`. Empty by default; user populates as
  needed (`.gitconfig`, `.ssh/known_hosts` additions, `.ssh/config`,
  etc.). Last-write-wins: VM-host skel overrides shipped skel.
- `/var/lib/mpd/state/` — mpd-managed operational state. `projects.json`,
  `databases.json`, `services.json`, `current-state.json`,
  `hooks-state.json`, `runtimes/runtime/` (the single runtime's entry),
  `dns/`. `dns/` holds the hosts files dnsmasq serves
  mpd's names from (`hostsdir=`, re-read on change — no restart). Wipe to
  reset.
- `/srv/` — the Podman data volume, bind-mounted onto the VM at `/srv` by
  the `srv.mount` unit and mounted into every container at the same path,
  so `/srv/projects/<name>` means the same thing on both sides. Holds
  per-project trees (projects/, data/, meta/), the database state (dbs/),
  third-party index repos (extra/), and backups (backups/ —
  `mpd --runtime-backup` writes `backups/runtime/<timestamp>/`). mpd reads and writes it as ordinary files
  from the VM; removal goes through `go/internal/srv`, which needs root
  because database engines own their data files.

`$HOME` is *not* used for anything mpd-owned; per-user concerns (SSH keys,
shell config, NSS DB) stay in `$HOME` and are not mpd's responsibility.

## Code layout

The binary is Go, built from `go/` into `bin/mpd` by `make install`:

- `go/cmd/mpd/main.go` — CLI entry: the flag set, the project verbs, dispatch
- `go/internal/cli/` — command implementations, listing and status
  rendering, setup orchestration, completion candidates
- `go/internal/vm/` — VM-host operations (fixed paths, identity,
  CA trust stores, resolver drop-in, motd, shutdown unit) plus the infra
  descriptors (`InfraServices`: dnsmasq + portal, systemd units on the VM)
- `go/internal/runtime/` — runtime provisioning and its state cache
- `go/internal/project/` — project scaffolding, env mutation, certs, rescan
- `go/internal/service/` — optional extra service containers (mailpit,
  adminer, seleniumv1): registry + lifecycle
- `go/internal/web/` — the status page `mpd --web` serves, behind the
  VM's caddy
- `go/internal/db/` — DB containers: tags, images, allocation, lifecycle
- `go/internal/control/` — `mpd` run from inside the runtime: the
  runtime's Unix socket, the FD-passing client/daemon, and the guard
  that decides what the runtime may ask the VM to do
- `go/internal/hooks/` — typed `Event` lifecycle hooks + asset-side
  `hooks/<event>.d/` dispatch
- `go/internal/srv/` — the data volume at `/srv`: reads, atomic writes,
  privileged removal
- `go/internal/state/` — the JSON state files under `/var/lib/mpd/state/`
- `go/internal/current/` — observed (as opposed to requested) state
- `go/internal/dnsmasq/` — DNS record files and their reconciliation
  (`dnsmasq.Reconcile`, records passed in by cli; `vm.ConfigureDnsmasq`
  owns the resolver itself)
- `go/internal/net/` — per-VM addressing: the single source of truth
- `go/internal/assets/` — reads the `assets/` tree
- `go/internal/podman/` — the Podman gateway (see the mandatory rule below)
- `go/internal/exec/` — the ONLY package that runs host commands
- `go/internal/cert/` — CA and leaf certificate generation. `ResolveSigner`
  decides which CA this VM signs with (zone-constrained intermediate, or a
  self-signed CA that is its own anchor); leaves carry their chain
- `go/internal/ui/` — the step/ok/warn output shapes

Runtime/project-type behavior + service container assets live under `assets/`:
- `assets/vm/` — VM-level assets deployed to the mpd VM itself: `motd`
  (→ `/etc/motd`), `prompt.bashrc` (→ a managed block in the dev user's
  `~/.bashrc`), `vimrc` (→ `~/.vimrc`, seeded once, never rewritten), and
  `mpd-virt.env`, the per-developer template seeded to
  `/var/lib/mpd/env/mpd-virt.env` (only when nothing is there — a
  managed VM normally receives the Mac's copy instead)
- `assets/runtime/...` — the runtime definition, both build phases in
  one place: `Containerfile`, `bootstrap.sh` (phase 1, root), `build.sh`
  (phase 2, dev user), `mpd-defaults.env`, `skel/`, `tools/`, `lib/`,
  `caddy/` (the in-runtime TLS frontdoor), `backup.d/`/`restore.d/`
  (`--runtime-backup`/`--runtime-restore` hooks),
  `project_types/{moodle,astro}/`
- `assets/services/<n>/...` — built service images (adminer's
  Containerfile; the other extras pull upstream images)
- `assets/completions/` — shell completion shims
- *defaults*, as opposed to that template, live next to their owners:
  `assets/runtime/mpd-defaults.env` and
  `assets/runtime/project_types/<type>/mpd-defaults.env`

## Canonical docs map

Topic owners — update the owning file for a topic instead of duplicating
across docs.

- `README.md` — project overview and entry point
- `docs/README.md` — documentation index
- `docs/CLI_BEHAVIOR.md` — CLI behavior contract (both modes)
- `docs/ARCHITECTURE.md` — repo architecture, mode split, networking summary, **verb/tool contract (§7)**
- `docs/HOOKS.md` — typed `Event` lifecycle hooks: events, audiences, asset-side `hooks/<event>.d/` scripts
- `docs/ROADMAP.md` — committed near-term work
- `docs/proposals/` — where a design doc for a parked / exploratory
  idea in *this* repo (mpd binary, in-VM behavior) goes. Create the
  directory when you write one; it is absent when there are none, and a
  proposal is deleted once it ships — the code and the canonical docs
  become the record, and git keeps the reasoning.
- *(Host-side design notes for the `mpd-virt` orchestrator live in
  that repo's own `docs/`.)*
- `docs/USAGE.md` — day-to-day workflow (bootstrap → first project → SSH-into-runtime)
- `docs/DEBUGGING.md` — symptom catalogue: real runtime/IDE failures, the diagnostic that confirms each, and the fix
- `docs/NETWORKING.md` — networking model (WireGuard overlay / SOCKS via mpd-virt + mpd-proxy)
- `docs/SECURITY.md` — security model
- macOS automation (Parallels / UTM) lives in the sibling `mpd-virt` repo: <https://github.com/mutms/mpd-virt>
- `setup/linux/README.md` — Ubuntu host + libvirt/KVM automation
- `setup/windows/README.txt` — Windows host + Hyper-V automation
- `setup/mpd-sandbox-setup.sh` — graphical "live in the VM" Debian sandbox (wgettable single script)

## Mandatory architecture rule

`go/internal/podman` is the single shared gateway for container
operations, and `go/internal/exec` is the only package permitted to run a
host command at all. Every other package (cli, runtime, project, service,
vm) must not shell out directly — they ask one of those two. Full rule +
review checklist in `docs/ARCHITECTURE.md` §"Mandatory Constraint".

## Mandatory privilege rule

Applies to runtime containers and the mpd VM — anywhere mpd ships
shell code for a host with a dev user plus passwordless sudo.

1. **Scripts run as the dev user.** Every shell asset under
   `assets/` and `mpd-virt/` is invoked as the dev user. The
   orchestrator (mpd's `podman exec -u <user>`, host-side ssh, etc.)
   is responsible for setting that identity at exec time. Scripts do
   not change identity themselves.
2. **`sudo` is for individual privileged commands only**, executed
   from inside a script that runs as the dev user. Allowed shapes:
   `sudo apt-get …`, `sudo install -d /opt/mpd`, `sudo systemctl …`,
   `sudo chown -R "$(id -un):$(id -un)" /opt/mpd`, `sudo tee
   /etc/profile.d/foo.sh`. `chown` is fine when scoped to
   dev-user-owned territory (`/opt/mpd`, `/srv/`).
3. **Never wrap a whole script in `sudo`.** No
   `sudo bash <whatever>.sh`. If a script needs many privileged ops,
   the script itself runs as the dev user and sudo's each one. The
   orchestrator never invokes a provisioning-shaped script as root
   (only `bootstrap.sh` is, by exception — see below).
4. **Never identity-switch to a non-root user.** All of the
   following are forbidden — anywhere in mpd shell code, no
   exceptions: `sudo -u <user>`, `runuser -u <user>`, `runuser
   <user>`, `su <user>`, `su - <user>`, `su <user> -c …`. If you find
   yourself reaching for one, the orchestrator is invoking the script
   with the wrong identity — fix that, don't switch in-script.

   *Elevation to root* via `su -c '<cmd>'` or `su -` / `su -l` (no
   target user — defaults to root) is **allowed**. The sandbox
   take-over bootstrap uses `su -c` to write the NOPASSWD sudoers
   drop-in on vanilla Debian (where the user isn't in the `sudo`
   group yet); the same one-shot/root-only pattern as `sudo bash -c`
   from inside the script.

**Single bootstrap exception.** The dev user must exist before
rule (1) can hold. Exactly one root-context script,
`assets/runtime/bootstrap.sh`, runs before the dev user exists
and creates it (along with sudoers, sshd, /etc/mpd identity, /srv
layout). The orchestrator (the `go/internal/runtime` provisioning
step) is the only caller. After it returns, phase 2 — `assets/runtime/build.sh`
— runs as the dev user via `podman exec -u <user>`. Nothing else
may invoke a script as root.

## Change discipline

- Keep changes scoped to the requested task. No drive-by refactors.
- Update affected docs when moving/renaming files.
- Prefer additive asset changes for runtime/project-type behavior; reserve
  Go edits for control-plane, state, networking, and orchestration.
- Prefer deterministic behavior over convenience fallbacks.
- **Never raise the `go` directive in `go/go.mod` above the Go that
  Debian Trixie packages** (`golang-go`, currently 1.24.x), and check a
  new dependency's own `go.mod` for the same. Go's default
  `GOTOOLCHAIN=auto` would otherwise silently download a 210 MB
  toolchain on every VM at build time. The Makefile pins
  `GOTOOLCHAIN=local` so this fails loudly instead; if you hit that
  failure, lower the directive or pick an older dependency version.
- Avoid cross-file doc duplication; link to canonical owners.
- For shell completion, edit `go/internal/cli/complete.go` — the shims
  under `assets/completions/` are stable forwarders and rarely need to
  change.
- **Each `setup/<name>/` directory must stay
  self-contained** — it's released as a small standalone bundle (a
  handful of `.sh` / `.ps1` / `.cmd` plus a README) and dropped onto a
  fresh host before the mpd repo is cloned. Scripts in there may only
  reference files inside the same directory plus standard host tooling
  and what they pull at runtime (`git clone`). Do **not** reach into a
  sibling platform directory or anywhere else in the repo from
  bootstrap-stage code; duplicate small helpers instead. See
  [`setup/README.md`](setup/README.md)
  for the full rule.

## Writing style in `assets/`

English text under `assets/` follows **ISO 24495-1:2023 (Plain
language)**. That covers the `.env` templates, the comment blocks in
tools and scripts, and anything else a developer reads there. The
standard's four principles, in the order to apply them:

1. **Relevant** — write what this reader needs *here*, and nothing else.
   How mpd implements a thing belongs in `docs/`; a pointer to the
   owning doc replaces the explanation.
2. **Findable** — one heading per setting, a blank line above it, lists
   as lists. Assume the reader is scanning for one key, not reading the
   file.
3. **Understandable** — short sentences, one idea each. Common words
   over precise-but-rare ones. Address the reader as "you". No symbols
   standing in for words (`∈`), no coined adjectives ("hot-switchable")
   where the plain fact is a sentence.
4. **Usable** — give the reader the command, and say what to run
   afterwards for the change to take effect.

The standard is written for readers working in a second language, which
most Moodle developers are. It applies to prose only: key names, values
and paths are what they are.

Two known tensions, both resolved toward the repo's own rules:

- Usability wants defaults restated where the reader is; **don't
  duplicate** wins — point at the file that owns the value, as
  "Avoid cross-file doc duplication" already requires.
- Plain language wants short files; a genuine safety explanation
  (`MPD_RUNTIME_CONTROL`, `MPD_DB=""` on astro) stays. Cutting the
  reason is not simplifying.

`docs/` and the Go sources are not covered — they address a different
reader, and code comments carry reasoning that plain-language rules are
not shaped for.

## Authoring verbs and tools

Verbs (host-side, surfaced as `mpd <verb> <project>`) and tools
(in-runtime, on PATH) are the extension surface for runtime + project-
type functionality. The contract — what a verb is vs. a tool, naming
conventions, PATH precedence, privilege model, idempotency — lives in
[`docs/ARCHITECTURE.md` §7](docs/ARCHITECTURE.md). Read that first;
this section is the "how to write one" follow-up.

### Decide: verb or tool?

> A capability is a **verb** if and only if it does work that the
> runtime container can't do for itself. Otherwise it's a **tool**.

Almost everything is a tool. The verb set is fixed and small — `create`,
`configure`, `start`, `stop`, `reset`, `run`, `delete`, `show`, `help`
— all Go, all in the control plane. Project-type-specific functionality (cron, phpunit,
composer, …) is exposed inside the runtime container where SSH sessions
and AI agents run; you reach it via PATH after `ssh mpd-<NNN>` from the
workstation, or `ssh mpd-<NNN>-runtime` / `ssh runtime` from inside the
VM (the aliases `mpd --vm-setup` writes into the VM's `~/.ssh/config`;
the long form `ssh user@runtime.<NNN>.mpd.test` is equivalent). In the VM
the bare `mpd-<NNN>` is that machine's own hostname, which is why the
short form is host-side only.

If you find yourself writing a verb whose body is essentially
`podman exec <container> <tool>`, you're writing a redundant verb.
Write only the tool.

### Adding a verb (rare)

Verbs are **Go**. Each one is a cobra command registered on the root in
`projectVerbCmds` (`go/cmd/mpd/main.go`); the handler it calls lives in
`go/internal/cli/project.go`.

To add a new verb:

- Add the handler func in `go/internal/cli/project.go`, taking
  `cli.ProjectDeps` like its neighbours.
- Add the cobra command to `projectVerbCmds` in `go/cmd/mpd/main.go`.
- Add the verb name to `cli.ProjectVerbs` in
  `go/internal/cli/complete.go` — that list is what reserves the name so
  a project can never collide with a verb, and what completion offers.
- Add it to `cli.ShowHelp` (`go/internal/cli/project.go`) so
  `mpd help <project>` lists it, and to the `projectCommands` block in
  `go/cmd/mpd/main.go` so `mpd --help` does.
- Add any flag suggestions to `verbArgs` in
  `go/internal/cli/complete.go`.
- Update `docs/CLI_BEHAVIOR.md` and the `Day-to-day commands` section
  in `docs/USAGE.md` if it belongs in the daily surface.

Global flags (`mpd --foo`) are declared on the root command in
`go/cmd/mpd/main.go` and acted on in its `dispatch` func. A flag that
acts on the VM itself takes the `--vm-` prefix (`--vm-setup`,
`--vm-stop`) so it can never be confused with the project verb of the
same name. Add it to `globalFlags` in `go/internal/cli/complete.go` too.

### Adding a tool

A tool is a single executable script under one of two locations,
chosen by scope:

- `assets/runtime/tools/` — runtime-wide, independent of project type.
  Examples: `claude-install`, `node-install`, `composer-install`, the
  `php` wrapper.
- `assets/runtime/project_types/<type>/tools/` — the project types,
  highest on PATH, so a type tool wins over a runtime tool of the same
  name.

Both are put on PATH by the skel `~/.bashrc` reading the assets tree
directly at `/opt/mpd/assets/...`. Nothing is copied or symlinked into
`/srv`. (There used to be a third, lower `runtime-base` tier; with one
runtime it earned nothing and merged into `assets/runtime/`.)

Skeleton (either location):

```bash
#!/bin/bash
set -euo pipefail
# Tool: <one-line description>.
# Runs as the dev user inside the runtime. May use sudo freely
# (see ARCHITECTURE.md §7 "Privilege model").

# Walk up from $PWD to find the project root (presence of mpd.env).
PROJECT_DIR="$PWD"
while [ ! -f "$PROJECT_DIR/mpd.env" ] && [ "$PROJECT_DIR" != "/" ]; do
    PROJECT_DIR="$(dirname "$PROJECT_DIR")"
done
if [ ! -f "$PROJECT_DIR/mpd.env" ]; then
    echo "Not inside a project tree (no mpd.env found)" >&2
    exit 1
fi

# Load the four-layer MPD_* env (runtime defaults → type defaults →
# /var/lib/mpd/env/mpd-virt.env → project mpd.env). source-mpd-env.sh uses a
# whitelist parser, so a malicious project mpd.env cannot inject code.
PROJECT_NAME="$(basename "$PROJECT_DIR")"
. /opt/mpd/assets/runtime/lib/source-mpd-env.sh

# Do the work. Idempotent if -install or -init.
...
```

Tools are bind-mounted at `/opt/mpd/assets/...` and put on
PATH from there by the skel `~/.bashrc`. Edits on the VM are immediately
visible inside the runtime — no rebuild, nothing to re-link.

#### Naming

- **Bare name** for upstream-known tools (`composer`, `php`,
  `phpunit`).
- **`mdl-` prefix** for Moodle-specific operations whose bare name
  would collide with system commands or be too generic (`mdl-cron`,
  `mdl-cache-purge`, `mdl-install`).
- **`-install` suffix** for "fetch the binary itself" (runtime-wide,
  one-shot, idempotent). Drops the binary into runtime FS — typically
  `/usr/local/bin/` — never under `/srv/`.
- **`-init` suffix** for "ready a project for the tool"
  (project-scoped, idempotent, may run many times across projects).

#### Idempotency (required)

`-install` tools must no-op cleanly when the target binary already
exists. `-init` tools must no-op cleanly when the project is already
initialized. Orchestrators call dependencies blindly without
guard-checking, so each tool guards its own work:

```bash
# composer-install pattern
if [ -x /usr/local/bin/composer ]; then exit 0; fi
# ... fetch + verify + install ...
```

```bash
# phpunit-init pattern
if mysql -u root -e "USE phpu_${PROJECT}_db" 2>/dev/null; then exit 0; fi
# ... drop-and-recreate ...
```

#### Wrapper tools — avoid PATH recursion

Tools whose bare name overrides a system binary (e.g.
`assets/runtime/tools/php` shadowing `/usr/bin/php`) must `exec` the
upstream binary by absolute path. Otherwise the wrapper recurses into itself:

```bash
# WRONG — recurses
exec php "$@"

# RIGHT — absolute path
exec /usr/bin/php8.4 "$@"
```

Look up the resolved version (e.g. from
`/srv/meta/<project>/project.json`) and exec the matching
`/usr/bin/phpX.Y` directly.

#### Privilege

Tools run as the dev user with passwordless `sudo` available. **Use
`sudo` *inside* the tool** for the operations that need root —
the dev/AI never types `sudo toolname`:

```bash
# correct — internal sudo on the privileged op:
sudo install -m 755 "$TMPDIR/binary" /usr/local/bin/binary
sudo systemctl restart php8.4-fpm

# correct — caller invokes the tool bare:
$ composer-install
```

Don't write tools that self-elevate (`if [ uid != 0 ]; then exec sudo
"$0"; fi`) — running the entire script as root via wholesale
escalation breaks least-privilege. Don't expect the caller to type
`sudo toolname` either — sudo's `secure_path` doesn't include the mpd
tool dirs, so the bare invocation through sudo would fail "command not
found." Internal sudo on specific operations is the right shape.

#### Testing checklist for a new tool

1. Rebuild the runtime: `mpd --runtime-rebuild` (prompts; `--yes`
   skips it, running projects are restored afterwards).
2. SSH in: `ssh mpd-<NNN>` (or `ssh runtime` from inside the VM).
3. `which <new-tool>` resolves to the expected path under
   `/opt/mpd/assets/`.
4. Run with no project context (negative test) — should fail
   gracefully with an actionable message.
5. `cd /srv/projects/<project>/` and run again — should succeed.
6. **Re-run immediately** (the idempotent path). Exits 0, no
   duplication.
7. For `-install` tools: confirm the binary lands under `/usr/local/bin/`
   or similar runtime FS, never `/srv/`.

#### What to update when adding a tool

- The tool itself (executable, `chmod +x`).
- If the tool deserves dev-facing mention: add a one-line entry under
  "Tools available inside the runtime" in `docs/USAGE.md`.
- If it replaces an existing verb (verb→tool migration): delete the
  obsolete verb files and update any host-side callers that referenced
  the verb by name.

## Pre-release validation

**Build / static checks** (run after any code or asset change):
- `make install` (writes `bin/mpd`)
- `make test vet fmt-check`
- `make lint-shell` after any shell-asset change (shellcheck over
  every shell file in the repo)
- skim affected docs for stale path / link references when moving or
  renaming files.

**Throw-away-VM smoke checks** (rerun freely — all idempotent):
- fresh VM via `setup/mpd-sandbox-setup.sh` (or `mpd-virt takeover`
  from a Mac)
- `mpd --vm-setup`, `mpd --vm-start`, `mpd --vm-status`
- optional: `mpd create/start/stop <project>` end-to-end including HTTPS hit
- `mpd --vm-stop`
