# mpd Architecture

Purpose: describe how `mpd` is structured, what is currently in scope, and where contributors should make changes.

## 1) Modes and Release Scope

`mpd` is a single Linux binary that runs inside a Debian Trixie VM
(under rootful Podman). Two user-facing modes share this binary:

- `mpd VM`: VM driven from the host by the separate `mpd-virt`
  orchestrator (own repo); headless by default, GNOME toggleable
  on demand. Primary target.
- `sandbox`: same Debian Trixie VM but with a GNOME desktop, set up
  in-VM via `setup/mpd-sandbox-setup.sh`. Same `mpd` binary;
  the host stays untouched.

Current scope:

- The Go control plane is the same for both modes — setup,
  lifecycle (`--vm-setup/--vm-start/--vm-stop/--vm-restart`, `--vm-status`,
  `mpd list`), runtime/project orchestration, extra-service
  reconciliation.
- There is no runtime mode distinction: identity is derived from the
  hostname `mpd-<NNN>` (`net.Current`), and sandbox vs managed differs
  only in how the CA is provisioned at setup (self-signed in-VM vs pushed
  by the host-side `mpd-virt`).
- Outstanding work is project-type coverage under
  `assets/runtime/project_types/` — not control-plane
  functionality.

## 2) Core Execution Model

High-level CLI flow:

1. CLI entry parses args and routes command type.
2. Preflight validates environment constraints.
3. Command dispatch selects project/runtime/service/global action.
4. Environment orchestration executes.
5. Persisted state is updated through state-owner APIs.

Control-plane lifecycle commands:

- `--vm-setup`
- `--vm-start`
- `--vm-stop`
- `--vm-restart`

These should remain stable even as implementation details evolve.

## 3) Mandatory Constraint: Host Command Boundary

This is a required architecture rule.

- Direct host OS command execution is allowed only in
  `go/internal/exec`. It is the only package that imports `os/exec`.
- All other packages (`cli`, `runtime`, `project`, `service`, `vm`) must
  not execute host commands directly.
- Cross-layer container/runtime operations must go through
  `go/internal/podman` only.

Allowed exception:

- `internal/podman` acts as the single shared command gateway for
  container/runtime management. It is itself a client of `internal/exec`.

### Binaries ownership rules

`internal/exec` holds an allow-list mapping each permitted command name
to an **absolute** path (`binaries` in `exec.go`). Commands are never
resolved through `PATH`: mpd runs privileged operations, and a pinned
path cannot be redirected by PATH manipulation. Adding an entry widens
what mpd can execute and is a deliberate act.
- Non-exec packages must not introduce new host-binary calls; they
  request Podman or `internal/vm` actions.

### Review/enforcement checklist

Any PR that adds command execution must answer:

1. Is this host command issued from `go/internal/exec`?
2. If not, can it be routed through `internal/podman` or moved into
   `internal/vm`?
3. Is the binary on the `internal/exec` allow-list, by absolute path?

### Sister rule: privilege model

A second mandatory rule governs **how** shell code runs inside runtime
containers and the mpd VM: scripts always run as
the dev user; `sudo` is for individual privileged commands; whole
scripts are never wrapped in `sudo`; identity-switching to a non-root
user (`sudo -u <user>`, `runuser`, `su - <user>`) is forbidden. Full
text in [`AGENTS.md` §"Mandatory privilege rule"](../AGENTS.md), with
the in-depth tool-level explanation in §7 below. Enforced in review;
`make lint-shell` (shellcheck) is the automated shell gate.

### Sister rule: host-side fenced `sudo` (linux bootstrap)

Bootstrap-stage shell scripts under
`setup/linux/lib/` run on the dev host
(not in a container or VM) and need `sudo` for a fixed set of operations
— route to the container subnet, DNS resolver pointing the VM's zone at
the in-VM dnsmasq, system-trust import of the mpd CA, plus
platform-specific extras (Firefox enterprise policy + cert under
`/etc/firefox/policies/`, Chromium's NSS DB). The pattern these
scripts follow:

1. **Detect first, no `sudo`.** Read current state with unprivileged
   tools (`route get`, `cat /etc/resolver/...`,
   `security find-certificate -a -Z`). Decide which operations are
   actually needed.
2. **Single fenced privileged block.** All `sudo` calls live in one
   contiguous block, gated by a single `sudo -v` (with a one-line
   explanation of *which* operations need it printed first), and
   terminated by an explicit `sudo -k` to invalidate the cached
   credential immediately.
3. **No `sudo` outside the fence.** Discovery, reporting, and state
   writes (`~/.mpd-virt/`, `~/.ssh/config`, `~/Desktop/`) all run
   as the user with no cached creds — a later bug cannot accidentally
   piggy-back on the elevated session.
4. **EXIT trap as backstop.** `trap 'sudo -k' EXIT` ensures cached
   creds are dropped even if the script errors before reaching the
   explicit `sudo -k`.
5. **Skip the fence entirely** when nothing needs to change. On a
   re-run where route, resolver, and CA are already correct, the user
   sees no password prompt at all.
6. **Generate the CA on the host before VM creation, and only on
   the host.** `prepare_host_ca` in `lib/common.sh` keeps the host
   CA at `~/.mpd-virt/ca/` (platform-owned; always present after
   the first `setup.sh` run).

   On a wipe, the next `setup.sh` regenerates and re-imports
   into the system trust store. Generation uses the bash twin of
   `cert.GenerateCA` (`go/internal/cert/ca.go`);
   the two generators must stay in sync. The CA is then uploaded into
   the VM, where mpd's reuse check (`go/internal/cli/setup.go`)
   picks it up. Route, resolver, **and** CA-trust collapse into a
   single upfront fenced block, after which the long unattended
   VM-creation phase runs holding no sudo creds.

   **Boundary rule:** CAs flow host → VM only. The host trust store
   only ever trusts certificates the host generated itself.
   `configure-client.sh` will not pull a CA off a VM and import it
   into the trust store — that would invert the trust direction by
   accepting a cert of unknown provenance from inside an SSH session.
   On a host with `~/.mpd-virt/ca/` empty (e.g. an imported VM
   created elsewhere), `configure-client.sh` configures route + DNS
   but skips CA import; the user has to bring a host CA across
   themselves.
7. **Optional dev override.** Before the fenced block opens,
   `print_sudo_recipe` in `lib/common.sh` lists the exact runnable
   commands and lets the dev choose to run them in another terminal
   instead of providing a password to the script. The recipe ends
   with a trailing `sudo -k` so the dev's terminal also drops cached
   creds. Idempotent predicates let the script re-check after the
   prompt and skip whatever the dev already did — the fenced block
   then runs only what's actually still missing, possibly nothing.

Reference implementations: `lib/setup.sh` (new-VM path: upfront fence,
host-first CA), `lib/configure-client.sh` (existing-VM and `start.sh`
warm path), and `lib/uninstall.sh` (teardown path).

This rule applies to the automated `mpd VM` platform whose
bootstrap runs shell as the dev user on the host: **linux**. The
macOS host side lives in the `mpd-virt` repo (Go, not shell; it keeps
its root CA at `~/.mpd-virt/conf/caroot/` and follows the same
host-first CA discipline). The other platforms differ:

- **windows** runs each entry script wholesale via UAC
  elevation (the `.cmd` shim's `Start-Process -Verb RunAs` is the
  privilege gate); the whole script body is the "fenced section" by
  design, and there is no per-operation `sudo`. CA generation and
  cloud-init seed ISO creation are delegated to WSL Debian bash
  (`lib/common.sh`) via `wsl -d Debian -u root`; no `openssl` or
  `genisoimage` runs in PowerShell.
- **sandbox** runs entirely inside the VM, so there is no "host-side
  bootstrap" to fence. `mpd-sandbox-setup.sh` enables passwordless sudo
  on the VM as part of taking it over (the hostname gate is
  the user's deliberate consent), then sudo's individual privileged
  commands per the in-VM rule.
- **Inside the VM and runtime containers**, the previous sister rule
  applies (per-command `sudo`, no whole-script elevation).

## 4) Repository Directory Contract

Fixed source checkout path: `/opt/mpd`

Directory ownership split:

- `bin/` — the built binary (`bin/mpd`) plus committed VM tools (`demo`, `claude-install`, `gnome-start`/`gnome-stop`), on PATH via `bootstrap/50-build.sh`.
- `/var/lib/mpd/conf/` — persistent local trust/network material:
  - `caroot/` — the trust anchor (`rootCA.pem`; public only, on a
    `mpd-virt`-provisioned VM) plus the CA this VM signs leaves with
    (`vmCA.pem`/`vmCA-key.pem`, constrained to its own zone)
  - `service/` — service TLS cert/key (the VM's zone apex, `<NNN>.mpd.test`)
  - `temp/` — short-lived cert operation files
- `/var/lib/mpd/` (other subdirs) — state/cache (machine metadata, runtime/project state, transient runtime files)

Project backups live inside the data volume at `/srv/backups/`, not on the
host filesystem (see §10).

Cleanup contract:

- The in-VM `mpd` has no `--uninstall` verb; the VM itself is the
  unit of removal (drop it via `mpd-virt` on the host).
- Manual cleanup of the VM's `/var/lib/mpd/` is just `rm -rf` — state and
  cache are designed to be safe to remove and rebuild.

## 5) State Model and Mutation Points

Primary persisted state domains:

- Persisted intent (`go/internal/state/`)
- Observed state (`go/internal/current/`)

State mutation convention:

- Persisted state writes should happen only in dedicated state-owner APIs.
- Command/orchestration code should request state changes via those APIs, not write JSON/files directly.
- Naming for mutators should be explicit (`upsert*`, `delete*`, `set*`, `mark*`).

Goal: keep state transitions auditable and prevent inconsistent partial writes.

### Persisted intent vs live observation

mpd splits resource state into two distinct concepts:

- **`requested`** — persisted intent, written to disk. Mutated *only*
  by explicit user actions: the project verbs (`mpd <p>
  create/start/stop/delete`), the runtime lifecycle (`mpd --vm-setup`
  creates the single runtime, `mpd --runtime-rebuild` recreates it),
  and the service flags (`mpd
  --service-enable/--service-disable/--service-uninstall/--service-purge`).
  Survives reboots. Lives in `state.Project.Requested`,
  `state.Runtime.Requested` and `state.Service.Enabled`
  (`go/internal/state/state.go`).
- **`current`** — live observation, computed on each query from
  podman (no persistence). Domain: `running`, `stopped`,
  `missing` (no container exists). Accessors:
  `current.Observer.Runtime`, `.Project`, `.DB` —
  `go/internal/current/current.go`.

Reconciliation closes the gap: `mpd --vm-start` walks `requested` and
brings `current` into agreement; `mpd --gc` (planned) does the
opposite trim. This is the same desired-vs-observed model used by
Kubernetes, systemd, and Terraform.

DBs have **no `requested` field** — they're emergent; DB lifecycle is
derived from runtime + project records (see `docs/HOOKS.md` §"Resource
lifecycle model"). Extra services **do** carry persisted intent:
`/var/lib/mpd/state/services.json` holds one entry per installed
service — presence means installed, `Enabled` decides whether it runs
(and auto-starts); absence means uninstalled. The enabled set is also
published to `/srv/meta/services.json` so in-runtime consumers
(`configure.sh`) can read it. The single runtime's record lives at
`/var/lib/mpd/state/runtimes/runtime/meta.json`.

Display layers show both columns side-by-side (`mpd list`,
`mpd <project> show`). Divergence — e.g.
`requested=running, current=stopped` after a reboot but before
`mpd --vm-start` — is legible from the listing alone.

Out-of-process consumers
don't have podman access, so they can't compute `current` themselves.
mpd writes a snapshot to
`/var/lib/mpd/state/current-state.json` (`current.Snapshot` —
runtimes/projects/databases name → status map plus a `refreshedAt`
timestamp), refreshed by the lifecycle commands
(`current.Observer.Refresh`). The portal reads live state through
`current.Observer` in-process. Nothing under `/var/lib/mpd/state/` is
mounted into containers; what the runtime gets instead is this VM's
addressing at `/srv/meta/vm.json` on the data volume.

## 6) Assets and Extension Contract

`assets/` is the extension surface for runtime/type behavior.

- The unified runtime's definition and provisioning: `assets/runtime/...`
  (`Containerfile`, `bootstrap.sh`, `build.sh`, `mpd-defaults.env`,
  `skel/`, `tools/`, `lib/`, `caddy/`, `backup.d/`, `restore.d/`)
- Project-type behavior: `assets/runtime/project_types/<type>/...`
  (current types: `moodle`, `astro`)
- Runtime / project-type tools: single executable per file under
  corresponding `tools/` (see §7). Verbs are Go, not assets.
- Service config/templates: `assets/services/...`

Contributor rule:

- Prefer additive asset changes for runtime/project-type customization.
- Reserve Go changes for control-plane, state, networking, and orchestration behavior.

## 7) Verbs and tools

`mpd` exposes two kinds of executables, with deliberately different
homes and audiences.

**Verbs** are run from outside the runtime by the `mpd` binary on the
host (or inside the VM, on `mpd VM`). They handle work that the
runtime container can't do for itself — provisioning DB containers,
writing project metadata, DNS records and certs, podman lifecycle. Surface:
`mpd <verb> <project>`. Lifetime: one invocation per CLI call.

*Where a verb is typed and where it runs are separate questions.* Project
verbs — along with db/service management, `--runtime-backup` and `list` —
can also be **typed inside a runtime**: the same binary detects it
is in a container and forwards the command to the VM over that runtime's
control socket, which executes it there. A compiled-in denylist fences
off only what would terminate the runtime the caller is standing in (the
VM lifecycle, the runtime lifecycle, the control-plane daemons);
everything else — deletes and purges included — is forwarded. That
does not make them tools —
the work is still VM-side, which is exactly why it has to be forwarded.
It only removes the second terminal. `internal/control` owns this; the
rule below is unaffected, and the split between the two categories is
untouched by it. Verb-vs-tool is about *who can do the work*, never about
where the developer happens to be sitting. See
[`SECURITY.md`](SECURITY.md#the-runtime-control-socket) for what a
runtime is allowed to ask for and why.

**Tools** are run from inside the runtime container — by a developer
in an SSH session, by an AI agent in the same SSH session, by a verb
that `podman exec`s into the runtime, or by another tool. They handle
work the runtime container can do for itself: running phpunit, doing a
Moodle install, fetching a binary into runtime FS. Surface: any
executable on PATH. Lifetime: ad-hoc.

The rule that decides which a thing should be:

> A capability is a **verb** if and only if it does work that the
> runtime container can't do for itself. Otherwise it's a **tool**.

Don't duplicate. If a tool covers a capability, the verb is redundant.
Convenience verbs that just `podman exec` into the runtime to run a
tool with no host-side coordination should not exist.

**`mpd run` is why that stays true.** One generic verb forwards any
command into the runtime that owns the current project, so the pressure
to add `mpd cron`, `mpd phpunit`, `mpd composer` — each a verb whose
whole body would be an exec — never arises:

```
cd /srv/projects/moodle51 && mpd run mdl-cron
```

It runs the command through a login shell, so the forwarded command sees
the same PATH as one typed inside the runtime; anything else would make
`mpd run <tool>` and `<tool>` behave differently, which is precisely the
trap a forwarder exists to avoid. The working directory is passed
verbatim, since `/srv` is one tree at one path on both sides.

An earlier design added VM-side *shims* — a `php` on the VM's PATH that
forwarded through `mpd run`. Dropped: `mpd run php …` is clear enough,
and claiming a bare upstream name on the VM would turn a wrong-terminal
mistake into a silent forward instead of an immediate `command not
found`. The VM deliberately has no PHP and no Node
(`bootstrap/40-install-software.sh` installs neither); that absence is a
useful signal and is worth keeping.

### Implementation: Go by default

Verbs are **Go**: cobra commands in `go/cmd/mpd/main.go`, handlers in
`go/internal/cli/project.go`. The verb set is fixed and small —
`create`, `configure`, `start`, `stop`, `reset`, `run`, `delete`,
`show`, `help` — all
control-plane code with direct access to `internal/podman` and the state
APIs. There is no asset-shipped-verb
mechanism: project-type-specific operations live inside the runtime as
**tools**, not as host-side verbs.

Previous asset-shipped verbs (Moodle: `cache-purge`, `cron`, `upgrade`,
`install`; Astro: `rebuild`, `upgrade`) all migrated to tools — they
were essentially `podman exec <tool>` wrappers, redundant with the
tool itself. The lesson generalised: if a host-side verb's body would
be `podman exec <container> <tool>`, write only the tool.

Tools are **shell** under `assets/.../tools/`. They run inside the
runtime as the dev user, so anything you'd naturally write in bash
(with optional `sudo` — see "Privilege model" below) is the right
shape.

### Asset layout

Tools ship as scripts under `assets/`, in two tiers chosen by scope:

```
assets/runtime/tools/                  # runtime-wide: any project
assets/runtime/project_types/<type>/tools/
                                       # type-only: for projects of that type
```

Both tiers are read straight out of the assets tree, which is
bind-mounted at `/opt/mpd` in every container at the same path it has on
the VM. Nothing is copied and nothing is symlinked. PATH precedence
across the two tiers is documented below.

(A third, lowest `assets/runtime-base/tools/` tier existed while the
runtime was built from a separate base layer. There is exactly one
runtime, so the layer earned nothing and was merged into
`assets/runtime/`; the two-phase *privilege* split it also held —
`bootstrap.sh` as root, `build.sh` as the dev user — is unchanged.)

### Lineage

The tool concept is inherited from MDC
([github.com/skodak/mdc](https://github.com/skodak/mdc/tree/main/bin)),
which had a single `bin/` directory mixing what `mpd` now calls verbs
(`mdc-start`, `mdc-stop`, `mdc-backup`, …) and tools (`phpunit`,
`behat`, `grunt`, `site-install`, …). `mpd` splits them by which side
of the runtime they execute on. Tools that match MDC's bare names and
upstream package names are kept verbatim (`phpunit`, `behat`, etc.);
operations whose bare name would be too generic or collide with
system commands take an `mdl-` prefix.

### PATH precedence

Inside the runtime, PATH is set so type tools win over runtime tools win
over system binaries:

```
/opt/mpd/assets/runtime/project_types/*/tools/   ← type tools first
/opt/mpd/assets/runtime/tools/                   ← runtime tools second
[normal system PATH]                             ← system fallback
```

PATH is set by the dev user's `~/.bashrc` (shipped via skel —
`assets/runtime/skel/.bashrc`), which prepends `runtime/tools/` and then
each project type's. Each prepends, so the last added ranks highest. The
type tier is self-extending — a new project type with a `tools/`
directory is picked up with no `.bashrc` edit.

The tree is read in place — nothing is copied and nothing is symlinked
into `/srv` — and `/opt/mpd` is the same tree on the VM and in the
container, so changing a tool takes effect immediately with no rebuild.

The dev user is the only login identity inside a runtime. **Root has
none of the mpd tool dirs on PATH** — `sudo composer install` returns
"command not found" by design (see AGENTS.md "Mandatory privilege rule").
Tools that need root sudo individual operations; whole tools never run
under sudo.

This means a tool named `php` overrides the system `php` when invoked
from anywhere inside the runtime as the dev user. The same holds for
`composer`, `node`, etc. A wrapper tool `exec`s the upstream binary by
absolute path (e.g. `exec /usr/bin/php8.4 "$@"`) to avoid recursing into
itself.

### Privilege model

Tools run as the dev user — the only non-root user inside the runtime,
created at provisioning time with the same UID as the developer's host
account so files written through the runtime land with the right owner
on the data volume. The dev user has **passwordless `sudo`** inside the
runtime by design (see [`SECURITY.md`](SECURITY.md)).

**Tools `sudo` internally; the dev/AI invokes them bare.** The right
shape is:

```bash
# In the tool: most work as the calling user, sudo only what needs root.
sudo install -m 755 "$TMPDIR/binary" /usr/local/bin/binary
sudo systemctl restart php8.4-fpm
```

```bash
# In an SSH session: just type the tool name.
$ composer-install
$ node-install
```

Not `sudo composer-install`. There are two reasons:

1. **`sudo`'s `secure_path` doesn't include the mpd tool dirs** — sudo
   resets PATH to a locked-down default, so `sudo composer-install`
   would fail with "command not found" even though the dev's PATH has
   it. Internal sudo sidesteps this entirely.
2. **Least privilege** — the script runs as the dev user, only the
   operations that genuinely need root run elevated. Easier to audit,
   easier to reason about.

Verbs run from outside the runtime. When a verb needs root inside the
container (e.g. for `-install` setup at provision time), it uses
`podman exec --user 0:0`. From inside the runtime, the equivalent is
just plain `sudo` inside the tool.

**Forbidden shapes (mandatory rule, see
[`AGENTS.md` §"Mandatory privilege rule"](../AGENTS.md)).** Three shapes
are banned anywhere in mpd shell code, with no exceptions:

1. Wrapping a whole script in `sudo` — `sudo bash <whatever>.sh`.
   If a script needs many privileged ops, it runs as the dev user
   and `sudo`s each one. Only `bootstrap.sh` is invoked as root, by
   the orchestrator, as the named bootstrap exception.
2. Identity-switching to a non-root user — `sudo -u <user>`,
   `runuser -u <user>`, `runuser <user>`, `su - <user>`,
   `su <user> -c …`. If you need a script to run as the dev user,
   the orchestrator (mpd's `podman exec -u`, ssh, etc.) sets that
   identity at exec time.
3. Re-execing the script as another identity from inside itself
   (any flavor of the above). Same root cause: identity belongs to
   the orchestrator, not the script.

A single bootstrap exception applies: the dev user must exist before
rule (1) can hold, so exactly one root-context script
(`assets/runtime/bootstrap.sh`) runs as root to create the user, the
sshd/sudoers setup and the `/srv` layout. The orchestrator is the only
caller. After it returns, phase 2 (`assets/runtime/build.sh`)
runs as the dev user via `podman exec -u`. Shapes (1) and (2) are
enforced in review.

### Naming conventions

**Bare names** are used for tools whose name matches a well-known
upstream package or whose meaning is clear from the bare word:
`composer`, `php`, `node`, `phpunit`, `behat`, `grunt`, `mpci`.

**`mdl-` prefix** for Moodle-project-type tools whose bare name would
be too generic or collide with system commands: `mdl-install`,
`mdl-cache-purge`, `mdl-cron`, `mdl-upgrade`,
`mdl-data-purge`. The prefix is also a usability cue — when an AI agent
or a human sees `mdl-cron` on PATH, it's unambiguously the
mpd-installed Moodle cron, not the system cron daemon.

**Suffixes**:

- `-install` — fetches/installs a tool into runtime FS (typically
  `/usr/local/bin/`, never under `/srv/`). Runtime-wide, one-shot.
  Examples: `composer-install`, `node-install`, `mpci-install`.
- `-init` — readies a tool's state for the *current* project
  (cwd-walks to find the project root, does whatever's needed).
  Project-scoped. May include some installation as a side effect (npm
  packages, composer deps, test DB), but the operation is "ready this
  project for the tool," not "fetch the tool." Examples: `phpunit-init`,
  `behat-init`.

The bare name (no suffix) is the wrapper that does the work on demand:
`phpunit`, `composer`, `php`, `node`. Suffixed tools sort adjacent to
their bare-name companion in directory listings and share a
tab-completion stem.

### Idempotency

Both `-install` and `-init` tools must be **idempotent** — safe to
call when their target is already present / already initialized,
exiting 0 with no changes. This lets orchestrator tools (e.g.
`mdl-install` calling `composer-install` and `mpci-install` to satisfy
prerequisites) invoke dependencies blindly without guard-checking
first.

### Composition

Tools may freely invoke other tools through PATH. The typical pattern:
project-type tools (`mdl-install`, `mdl-upgrade`) orchestrate by
calling runtime-level setup tools (`composer-install`, `mpci-install`)
as prerequisites, then doing project-specific work. Runtime-level
tools are typically the leaves of the call graph; they don't depend on
project-level state.

For practical authoring guidance (file templates, `$PWD` walking,
testing checklist), see [`AGENTS.md`](../AGENTS.md) §"Authoring verbs
and tools".

## 8) Configuration model: mpd.env

`mpd.env` files carry runtime configuration that the user is meant to edit:
DB tag, PHP version, Moodle install defaults, headless-Behat toggle, etc.
Five named files with distinct lifecycles. Four are *sourced* at every
`configure`/`start` invocation (the layered hierarchy); the fifth is a
*seed* used once at project create time.

| File             | Path                                                                                      | Owner                                                                                         | Purpose                                                              |
|------------------|-------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------|----------------------------------------------------------------------|
| Runtime defaults | `assets/runtime/mpd-defaults.env`                                                         | runtime, in repo (read-only)                                                                  | "the default value" for runtime-wide keys; sourced 1st               |
| Type defaults    | `assets/runtime/project_types/<type>/mpd-defaults.env`                                    | project type, in repo (read-only)                                                             | type-specific overrides of the runtime default; sourced 2nd          |
| VM-wide          | `/var/lib/mpd/env/mpd-vm.env` (host; bind-mounted RO into the runtime container at the same path) | developer (manual edit)                                                                       | cross-project preferences and secrets; sourced 3rd                   |
| Per-project      | `/srv/projects/<n>/mpd.env`                                                               | seeded by `project-create.sh`, mutated by `mpd configure <project> KEY=VALUE` and manual edit | project-scoped truth; sourced 4th, wins                              |
| Per-type seed    | `assets/runtime/project_types/<type>/mpd-template.env`                                    | project type, in repo (read-only)                                                             | NOT sourced — copied to `/srv/projects/<n>/mpd.env` at `create` time |

**Seeding** (one-shot, at create time): at `mpd create <project>`, the
project type's `project-create.sh` copies `mpd-template.env` to the project
as `mpd.env` *only if absent* — pre-existing mpd.env (e.g. from a clone or
hand-staged) is sacred. The seed file is not the source of defaults; it's a
starting point for the user's own per-project overrides, with commented
hints for discoverability.

**Sourcing order at runtime** (in
`assets/runtime/lib/source-mpd-env.sh`):

1. runtime defaults (`mpd-defaults.env`)
2. type defaults (`mpd-defaults.env`)
3. `/var/lib/mpd/env/mpd-vm.env`
4. project `mpd.env`

The project's type is read from `/srv/meta/<n>/project.json` (written
by `project.WriteMeta`) using `jq`; the runtime layer is unconditional,
there being one runtime. Bash "last assignment wins" gives
the right semantics — each layer overrides earlier ones, and explicit
`KEY=""` blocks fall-through:

| layer-1 (runtime)     | layer-2 (type)        | layer-3 (user)        | layer-4 (project)     | result                   |
|-----------------------|-----------------------|-----------------------|-----------------------|--------------------------|
| `MPD_PHP_VERSION=8.3` | (absent)              | (absent)              | (absent)              | `8.3`                    |
| `MPD_PHP_VERSION=8.3` | `MPD_PHP_VERSION=8.2` | (absent)              | (absent)              | `8.2` (type override)    |
| `MPD_PHP_VERSION=8.3` | `MPD_PHP_VERSION=8.2` | `MPD_PHP_VERSION=8.4` | (absent)              | `8.4` (user override)    |
| `MPD_PHP_VERSION=8.3` | (absent)              | (absent)              | `MPD_PHP_VERSION=8.5` | `8.5` (project override) |

`MPD_DB` is the same: a project type that doesn't use a DB ships `MPD_DB=""`
in its `mpd-template.env` (astro) so the seeded project file blocks
any `MPD_DB=...` the developer set in mpd-vm.env; types that do ship a
sensible default (`MPD_DB=postgres:latest` for moodle).

**How `mpd-vm.env` reaches the runtime:** the host file
`/var/lib/mpd/env/mpd-vm.env` is bind-mounted RO into the runtime
container at the same absolute path (`podman.EnvMountRO` in
`go/internal/podman/podman.go`). Directory mount, so vim/nano
atomic-rename writes on the host propagate inside the container
immediately. No sync, no restart needed.

**Naming convention:**

- `MPD_<RUNTIME>_<TYPE>_<KEY>` — project-type-specific knobs
  (`MPD_PHP_MOODLE_BEHAT`, `MPD_NODE_ASTRO_PORT`).
- `MPD_<RUNTIME>_<KEY>` — runtime-wide, applies to every type on that
  runtime (`MPD_PHP_VERSION`, `MPD_PHP_XDEBUG_MODE`).
- `MPD_<KEY>` — global mpd infra (none currently in active use; the
  former `MPD_DNS_UPSTREAM` is gone — dnsmasq reads the host's
  systemd-resolved upstream and follows whatever the host has configured).
- **Reserved keys:** `MPD_DB` is owned by `db.ParseTag`
  (engine whitelist + version regex); other reserved keys get strict
  validators in `project.ParseMutations` (`go/internal/project/env.go`)
  as they're added.

**CLI surface for editing:** `mpd configure <project> KEY=VALUE [...]`
parses positional pairs matching `^MPD_[A-Z0-9_]+=.*$`, sanitises in Go
(reserved-key map for strict validators, otherwise a generic safe-charset
check that blocks shell metacharacters), and rewrites the corresponding line
in `/srv/projects/<n>/mpd.env` via
`assets/runtime/tools/set-mpd-env`. Empty value deletes the line.
After mutations are applied, the project type's `configure.sh` sources the
layered env, generates config files, and emits resolved values into
`/srv/meta/<n>/effective.json` (where mpd reads `dbTag` to provision the
DB container).

## 9) Identity: the hostname

A VM's identity is derived from its **hostname**, `mpd-<NNN>`, by
`net.Current()` — the id `NNN`, the zone `<NNN>.mpd.test`,
the container subnet `10.163.<NNN>.0/24`, and every name keyed on it. The
VM's own LAN IP is read live off the interface (`vm.PrimaryIP()`), not
recorded. The hostname is the single source of truth: it's what the
hypervisor-side prep (or cloud-init) sets, what the user sees in their
prompt, and what a re-imaged VM changes.

Sandbox vs managed is **not** a runtime distinction — the same code paths
run in both. They differ only at *setup* in how the CA is provisioned:
`mpd --vm-setup` generates a self-signed CA in the VM when none was pushed
(sandbox), or uses the name-constrained per-VM CA that host-side `mpd-virt`
pushed (managed). A sandbox can be adopted as a managed VM later; the
takeover re-roots the CA and the projects survive.

`/var/lib/mpd/conf/` remains the durable-config dir (CA under `caroot/`,
service certs under `service/`) — it survives runtime-state wipes; the rest
of `/var/lib/mpd/` is state cache.

## 10) Backup persistence

Goal: Moodle-style project backups (dataroot tar + DB dump produced by a
shell script) have one well-defined path off the data volume, identical
across modes.

`/srv/backups` is a subdirectory of the `mpd-data-volume` data volume.
Every container that mounts the volume sees the same content there, and
so does the VM: `srv.mount` bind-mounts the volume onto `/srv`, so the
path is identical on both sides.

Read/write contract:

- **Project backup tools write here.** Project-type-specific tools
  (e.g. the planned `mdl-backup` under
  `assets/runtime/project_types/moodle/tools/`) tar dataroot +
  DB dumps into `/srv/backups/` from inside the runtime. Backup is
  currently a Moodle-only concern; other project types keep state in
  the source tree (so `git` is their backup mechanism).
- **Runtime backups write here too.** `mpd --runtime-backup` runs the
  hook scripts under `assets/runtime/backup.d/NN-*.sh` inside the
  runtime as the dev user, each receiving the backup directory as
  `$1`; the result lands in `/srv/backups/runtime/<UTC-timestamp>/`
  with a `manifest.json`. `mpd --runtime-restore` replays the newest
  backup through `assets/runtime/restore.d/NN-*.sh`. The shipped hooks
  cover the home-directory pieces worth carrying across a
  `--runtime-rebuild`: Claude Code config (`~/.claude`,
  `~/.claude.json`) and shell history. Configuration only, never
  binaries — a rebuild exists to reinstall everything fresh, so restore
  hooks re-run installers (`claude-install`) instead of copying
  executables back. Deliberately distinct from project backups above —
  the runtime is cattle with a carry-on bag, projects have their own
  (planned) tooling.
- **The VM is the exit/entry point.** From the dev's laptop:
  `scp <vm>:/srv/backups/<file> .` pulls a backup off; reverse direction
  stages a restore. No dedicated endpoint and no extra host key — this
  is the same SSH connection the developer already uses to reach the
  `mpd` CLI, so it works in both modes and needs no overlay or proxy.

Wipe contract:

- `podman volume rm mpd-data-volume` (or anything that wipes the Podman
  whole VM) deletes `/srv/backups/` along with everything else on the volume.
- Before wiping, copy anything you want to keep off the VM.
- This is intentional: `/srv/backups/` is the single transit point, so
  there's exactly one place to remember.

## 11) Networking, DNS, and TLS (Summary)

- Laptop ↔ VM transport is two ways: the **mpd-proxy WireGuard overlay**
  (daily, transparent, several VMs at once — the tunnel carries the whole
  `10.163.<NNN>.0/24`, so the laptop reaches project URLs, databases and
  service containers at their own addresses) or a **SOCKS-over-SSH**
  tunnel (`ssh -N mpd-<NNN>-socks`, sudo-free, one VM — the simple path
  for a new dev; terminates at sshd and reaches the same subnet from
  there). Both driven by the host-side `mpd-virt` orchestrator + its
  `mpd-proxy` helper (separate repos). An in-VM nft firewall seals the
  subnet from LAN/public ingress — only the bridge and `wg0` may route
  into it — so the VM exposes only sshd + WireGuard.
- Addressing is per-VM: `<NNN>` is the VM's id (from its hostname
  `mpd-<NNN>`), used as both the
  third octet of the subnet and the first label of the DNS zone, so
  several VMs are reachable from one workstation at once. Fixed host
  octets: `.1` gateway/VM, `.2` the runtime, `.10–.99` databases,
  `.100–.199` extra service containers. The `net` package
  (`go/internal/net/net.go`) is the single source of truth; nothing else should
  contain `10.163.` or `mpd.test` as a literal.
- dnsmasq runs **on the VM** (not in a container) and is authoritative for
  `.test`, bound to the gateway `.1`. The laptop reaches it through the
  overlay's split-DNS resolver (`/etc/resolver/mpd.test` → mpd-proxy → the
  right VM) or the SOCKS tunnel's remote DNS. Podman's own DNS is disabled
  on the network so nothing else holds port 53 on the gateway.
- TLS certs are signed by the local `mpd` CA: per-project certs (served by
  the in-runtime caddy) and the VM's own service cert, whose single SAN is
  the zone apex — the only name the VM's caddy serves. Extra services are
  plain HTTP and have no certs.

Always-on infra (`vm.InfraServices()`, `go/internal/vm/infra.go` —
deliberately distinct from the optional extra *services* below):

- `dnsmasq` — not a container: Debian's `dnsmasq-base` on the VM as the
  system unit `mpd-dnsmasq.service`, listening on the bridge gateway.
  Authoritative for `.test`; records are hosts files under
  `/var/lib/mpd/state/dns/`, which it re-reads on change without a
  restart. See docs/NETWORKING.md
- the **portal** is not a container: `mpd --web` runs on the VM as the
  user unit `mpd-web.service`, listening on `127.0.0.1:8099`, with
  Debian's caddy in front of it on the bridge gateway terminating TLS for
  the zone apex — the only name the VM's caddy serves. `--vm-setup`
  installs caddy, renders `/etc/caddy/Caddyfile` and restarts the unit,
  so editing a template needs only `make install && mpd --vm-setup`.

Inside the runtime — the TLS frontdoor:

- `mpd-caddy.service` runs the apt-installed caddy **as the dev user**
  (the only identity that can read the 0600 dev-owned project keys under
  `/srv/meta/<project>/`). `assets/runtime/caddy/mpd-caddy.sh` renders
  `/run/mpd-caddy/Caddyfile` from every project's
  `/srv/meta/<project>/urls.json`, watches `/srv/meta` by inotify, and
  validates + force-reloads on change. Project DNS records point at the
  runtime's `.2`; certs are still generated on the VM into
  `/srv/meta/<project>/`.
- Project URLs are project-type-driven (via `configure.sh` writing
  `urls.json`, each URL carrying a `kind` and a backend: php-fpm,
  reverse-proxy, redirect) — the control-plane Go code never hard-codes
  URL shapes.

Optional extra services (`go/internal/service/` — nothing installed by
default; plain HTTP at their own addresses, reached over the overlay or
SOCKS, never proxied by any caddy):

- `mailpit` — `.100`, `http://mailpit.svc.<NNN>.mpd.test:8025/`
  (SMTP `:1025`). One shared inbox; a mailpit-enabled project publishes
  an informational "mail" link filtered to it
  (`?q=<project>.<zone>`). Mail data lives on the `mpd-svc-mailpit`
  volume, which survives uninstall.
- `adminer` — `.102`, `http://adminer.svc.<NNN>.mpd.test:8080/`.
- `seleniumv1` — `.103`, `http://seleniumv1.svc.<NNN>.mpd.test:4444/`
  ("v1" so a future Moodle release can require another selenium
  alongside). Auto-enabled by `mpd configure` when a project sets
  `MPD_PHP_MOODLE_BEHAT=1`.

Lifecycle: `--service-enable` installs, starts and makes it auto-start
(`--restart always` + a reconcile in `--vm-start`/`--vm-setup`);
`--service-disable` stops it and sticks across reboots;
`--service-uninstall` removes the container but keeps its data volume;
`--service-purge` removes the volume too. Intent persists in
`/var/lib/mpd/state/services.json` (see §5).

### Laptop-side split DNS

With the **mpd-proxy** overlay the laptop has a single
`/etc/resolver/mpd.test` (→ mpd-proxy's forwarder on `127.0.0.1:5354`),
which fans `*.mpd.test` out to each VM's own dnsmasq through the tunnel —
written once, untouched as VMs come and go. With the **SOCKS** path there
is no host resolver entry at all: the dedicated browser does remote DNS
through the proxy. See [`NETWORKING.md`](NETWORKING.md).

Windows is the awkward case. The built-in NRPT mechanism
(`Add-DnsClientNrptRule`) works for most queries but is bypassed by some
clients (notably Chromium's async resolver) and interacts poorly with
corporate VPN clients. The recommended fallback is to install a small
local DNS forwarder on the laptop, point the system resolver at `127.0.0.1`,
and let the forwarder split queries by domain (`*.<NNN>.mpd.test → 10.163.<NNN>.1`,
everything else → system upstream).

**Recommended tool: Acrylic DNS Proxy** — Windows-only, MSI installer with
tray icon, one-file config. This is the established precedent on Windows:
Laravel Valet for Windows (the `cretueusebiu/valet-windows` port and its
descendants) ships Acrylic and configures it to resolve `*.test → 127.0.0.1`,
mirroring what macOS Valet does with `/etc/resolver/`. So the split-DNS story
is symmetric: macOS uses the OS-native `/etc/resolver/<domain>` mechanism,
which Apple's own [`container`](https://github.com/apple/container) tool also
uses. It takes any domain rather than only a TLD, which is what lets mpd give
each VM its own file for `<NNN>.mpd.test` where Valet has one file covering
all of `test`. Windows uses Acrylic because the OS has no native equivalent —
both are the convention rather than a mpd-specific choice. Alternatives considered:
`dnscrypt-proxy` (cross-platform, but its "encrypted DNS" framing confuses
non-privacy users) and Deadwood from the MaraDNS suite (works, but obscure on
Windows). We recommend Acrylic for the intended audience; the others are fine
for users who already know them.

See detailed docs:

- [`NETWORKING.md`](NETWORKING.md), [`SECURITY.md`](SECURITY.md)

## 12) Repository Layer Map

- `go/cmd/mpd/` — CLI entry: flag set, project verbs, dispatch
- `go/internal/cli/` — command implementations, listing and status
  rendering, setup orchestration, completion
- `go/internal/vm/` — VM-host operations (paths, identity, CA trust
  stores, resolver drop-in, motd, shutdown unit) and the VM-integral
  infra registry (dnsmasq + portal, `vm.InfraServices`)
- `go/internal/runtime/`, `go/internal/project/`, `go/internal/db/` —
  orchestration and records
- `go/internal/service/` — the optional extra service containers
  (mailpit, adminer, seleniumv1): registry and lifecycle
- `go/internal/hooks/` — typed `Event` lifecycle hooks
- `go/internal/state/`, `go/internal/current/` — persisted intent and
  observed state
- `go/internal/podman/`, `go/internal/exec/` — the two command gateways
- `go/internal/net/`, `go/internal/dnsmasq/`, `go/internal/cert/` —
  addressing; DNS record files and their reconciliation
  (`dnsmasq.Reconcile`, records passed in by the cli layer); TLS
- `assets/` — runtime/type/service scripts/config/templates + `runtime/skel/`
- `bootstrap/` — VM bring-up steps 10–50 (passwordless sudo, repo clone, apt, build)
- `setup/` — host-side bootstrap: the sandbox + takeover-prep scripts, `linux/`, `windows/` (macOS lives in the `mpd-virt` repo)
- `docs/` — behavioral and architecture contracts

## 13) Contributor Change Map

If you change:

- CLI behavior: update `docs/CLI_BEHAVIOR.md`
- Runtime/project behavior: update `assets/runtime/...` and matching docs
- Networking/TLS/DNS behavior: update networking/security docs for affected mode
- State shape or mutation behavior: update this file and relevant state docs/comments

## 14) Non-Goals (Current)

- Multi-tenant isolation or production hardening
- Binary distribution via git repository

## 15) Related Docs

- `docs/README.md` — documentation index
- `docs/CLI_BEHAVIOR.md` — CLI behavioral reference
- `docs/HOOKS.md` — typed lifecycle hooks
- `AGENTS.md` — practical authoring guidance for verbs and tools (§"Authoring verbs and tools")
