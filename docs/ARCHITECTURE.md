# mpd Architecture

Purpose: describe how `mpd` is structured, what is currently in scope, and where contributors should make changes.

## 1) Modes and Release Scope

`mpd` has two execution modes:

- `mpd-desktop`: native macOS mode using Podman Desktop and local service/runtime orchestration.
- `mpd-machine`: dedicated virtual-machine workflow.

Current scope:

- Both `mpd-desktop` and `mpd-machine` ship as supported execution modes.
- The Swift control plane is at parity across modes — setup, lifecycle (`--setup/--start/--stop/--uninstall`, `--status`, `mpd list`), runtime/project orchestration, and per-runtime sidecar reconciliation work the same way on both.
- Mode-specific surfaces are limited to host integration: `mpd-desktop` runs on top of Podman Desktop with a WireGuard bootstrap; `mpd-machine` runs under rootful Podman in a dedicated Debian Trixie VM with plain L3 routing from the laptop.
- The `mpd-machine/` directory additionally holds bootstrap scripts and platform-specific setup logic (currently `platforms/macos-utm/` and `platforms/generic-vm/`) that will grow into setup packages/installers.
- Outstanding work is project-type coverage under `assets/runtimes/<runtime>/project_types/` — shared by both modes — not control-plane functionality.

## 2) Core Execution Model

High-level CLI flow:

1. CLI entry parses args and routes command type.
2. Preflight validates environment constraints.
3. Command dispatch selects project/runtime/service/global action.
4. Environment-specific orchestration executes (`desktop` or `machine` path).
5. Persisted state is updated through state-owner APIs.

Control-plane lifecycle commands:

- `--setup`
- `--start`
- `--stop`
- `--uninstall`

These should remain stable even as implementation details evolve.

## 3) Mandatory Constraint: Host Command Boundary

This is a required architecture rule.

- Direct host OS command execution is allowed only in `Environment/Desktop/*` and `Environment/Machine/*`.
- All other layers (`CLI`, `Runtime`, `Service`, `Core`) must not execute host commands directly.
- Cross-layer container/runtime operations must go through `Mpd.Podman.*` only.

Allowed exception:

- `Mpd.Podman` acts as the single shared command gateway for container/runtime management.

### Binaries ownership rules

`Mpd.Environment.Binaries` defines context-specific host binaries and is split by execution context.

- Desktop-only host tools belong to `Environment/Desktop` usage paths.
- Machine-only host tools belong to `Environment/Machine` usage paths.
- Shared binary definitions are allowed only when semantics are identical in both contexts.
- Non-environment layers must not introduce new host-binary calls; they request environment or Podman actions.

### Review/enforcement checklist

Any PR that adds command execution must answer:

1. Is this host command in an `Environment/*` file?
2. If not, can it be routed through `Mpd.Podman` or moved into `Environment/*`?
3. Is binary resolution sourced from `Mpd.Environment.Binaries` for the correct context?

### Sister rule: privilege model

A second mandatory rule governs **how** shell code runs inside runtime
containers, the mpd-machine VM, and fileaccess: scripts always run as
the dev user; `sudo` is for individual privileged commands; whole
scripts are never wrapped in `sudo`; identity-switching to a non-root
user (`sudo -u <user>`, `runuser`, `su - <user>`) is forbidden. Full
text in [`AGENTS.md` §"Mandatory privilege rule"](../AGENTS.md), with
the in-depth tool-level explanation in §7 below. Enforced by `make
check-privilege-boundary`.

## 4) Repository Directory Contract

Fixed source checkout path: `~/Developer/mpd`

Directory ownership split:

- `bin/` — local built binaries (`bin/mpd`); executable path checks depend on this.
- `conf/` — persistent local trust/network material:
  - `caroot/` — root CA keypair/fingerprint
  - `wireguard/` — WireGuard keys and tunnel config (mpd-desktop only; mpd-machine reaches containers via plain routing)
  - `service/` — service TLS cert/key (`mpd.test`)
  - `temp/` — short-lived cert operation files
  - `platform.env` — host platform identity (see §9)
- `~/.mpd/` — state/cache only (machine metadata, runtime/project state, transient runtime files)

Project backups live inside the data volume at `/srv/backups/`, not on the
host filesystem (see §10).

Uninstall contract (desktop):

- `mpd --uninstall` removes `~/.mpd/` state only.
- `~/Developer/mpd/conf/` is intentionally preserved.
- manual user cleanup may remove `~/Developer/mpd/` when desired.

## 5) State Model and Mutation Points

Primary persisted state domains:

- Core/global state (`mpd/mpd/Core/*`)
- Runtime/project state (`mpd/mpd/Runtime/*`)

State mutation convention:

- Persisted state writes should happen only in dedicated state-owner APIs.
- Command/orchestration code should request state changes via those APIs, not write JSON/files directly.
- Naming for mutators should be explicit (`upsert*`, `delete*`, `set*`, `mark*`).

Goal: keep state transitions auditable and prevent inconsistent partial writes.

## 6) Assets and Extension Contract

`assets/` is the extension surface for runtime/type behavior.

- Runtime definitions and provisioning: `assets/runtimes/<runtime>/...`
- Project-type behavior: `assets/runtimes/<runtime>/project_types/<type>/...`
- Runtime / project-type tools: single executable per file under
  corresponding `tools/` (see §7). Verbs are Swift, not assets.
- Service config/templates: `assets/services/...`, `assets/templates/...`

Contributor rule:

- Prefer additive asset changes for runtime/project-type customization.
- Reserve Swift changes for control-plane, state, networking, and orchestration behavior.

## 7) Verbs and tools

`mpd` exposes two kinds of executables, with deliberately different
homes and audiences.

**Verbs** are run from outside the runtime by the `mpd` binary on the
host (or inside the VM, on `mpd-machine`). They handle work that the
runtime container can't do for itself — provisioning DB containers,
attaching sidecars, writing project metadata, podman lifecycle. Surface:
`mpd <verb> <project>`. Lifetime: one invocation per CLI call.

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

### Implementation: Swift by default

Verbs are **Swift**, in `mpd/Runtime/`, `mpd/CLI/`, etc. The verb set
is fixed and small — `create`, `configure`, `start`, `stop`, `delete`,
`show` — all Swift control-plane methods with direct access to
`Mpd.Podman.*`, state APIs, and sidecar reconciliation. There is no
asset-shipped-verb mechanism: project-type-specific operations live
inside the runtime as **tools**, not as host-side verbs.

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

Tools ship as scripts under `assets/`, in three tiers chosen by scope:

```
assets/runtime-base/tools/             # cross-runtime: works in any Trixie runtime
assets/runtimes/<runtime>/tools/       # runtime-wide: only in this runtime
assets/runtimes/<runtime>/project_types/<type>/tools/
                                       # type-only: only when a project of this type is in the runtime
```

`runtime-base/tools/` is symlinked into `/srv/tools/_base/` by
`bootstrap.sh`. The other two tiers are symlinked into `/srv/tools/<runtime>/`
and `/srv/tools/<type>/` by the runtime's `build.sh`. PATH precedence
across the three tiers is documented below.

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

Inside the runtime, PATH is set so type tools win over runtime tools
win over base tools win over system binaries:

```
/srv/tools/<every-project-type-active-in-the-runtime>/   ← type tools first
/srv/tools/<runtime>/                                    ← runtime tools second
/srv/tools/_base/                                        ← runtime-base tools third
[normal system PATH]                                     ← system fallback
```

Profile.d files are sourced alphabetically and each prepends to PATH;
naming guarantees the order:

- `mpd-tools-base.sh` (sourced first → ends up lowest in mpd's tiers)
- `mpd-tools-runtime.sh` (sourced second → middle)
- `mpd-tools-type-<type>.sh` (sourced last → highest)

This means a tool named `php` overrides the system `php` when invoked
from anywhere inside the runtime. The same holds for `composer`,
`node`, etc. A wrapper tool `exec`s the upstream binary by absolute
path (e.g. `exec /usr/bin/php8.4 "$@"`) to avoid recursing into
itself.

Project-type tool dirs are added to PATH unconditionally for any
project type that ships under `assets/runtimes/<runtime>/project_types/`.
Name collisions across project types are resolved by PATH order, by
design ("if not unique — bad luck").

### Privilege model

Tools run as the dev user — the only non-root user inside the runtime,
created at provisioning time with the same UID as the developer's host
account so files written through the runtime land with the right owner
on the data volume. The dev user has **passwordless `sudo`** inside the
runtime by design (see
[`desktop/SECURITY.md`](desktop/SECURITY.md) and
[`machine/SECURITY.md`](machine/SECURITY.md)).

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

1. **`sudo`'s `secure_path` doesn't include `/srv/tools/`** — sudo
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
   the orchestrator (Swift `podman exec -u`, ssh, etc.) sets that
   identity at exec time.
3. Re-execing the script as another identity from inside itself
   (any flavor of the above). Same root cause: identity belongs to
   the orchestrator, not the script.

A single bootstrap exception applies: the dev user must exist before
rule (1) can hold, so exactly one root-context script
(`assets/runtime-base/bootstrap.sh`) runs as root to create the user
plus the rest of the runtime base. The orchestrator is the only
caller. After it returns, phase 2 (`assets/runtimes/<rt>/build.sh`)
runs as the dev user via `podman exec -u`. `make
check-privilege-boundary` enforces shapes (1) and (2).

### Naming conventions

**Bare names** are used for tools whose name matches a well-known
upstream package or whose meaning is clear from the bare word:
`composer`, `php`, `node`, `phpunit`, `behat`, `grunt`, `mpci`,
`site-install`.

**`mdl-` prefix** for Moodle-project-type tools whose bare name would
be too generic or collide with system commands: `mdl-install`,
`mdl-cache-purge`, `mdl-cron`, `mdl-upgrade`, `mdl-backup`,
`mdl-restore`. The prefix is also a usability cue — when an AI agent
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
  `behat-init`, `node-init`.

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

| File | Path | Owner | Purpose |
|---|---|---|---|
| Runtime defaults | `assets/runtimes/<rt>/mpd-defaults.env` | runtime, in repo (read-only) | "the default value" for `MPD_<RT>_*` keys; sourced 1st |
| Type defaults | `assets/runtimes/<rt>/project_types/<type>/mpd-defaults.env` | project type, in repo (read-only) | type-specific overrides of the runtime default; sourced 2nd |
| Per-developer | `~/.mpd/mpd-user.env` (host) → `/srv/personal/mpd-user.env` (synced into the data volume) | developer (manual edit) | cross-project preferences and secrets; sourced 3rd |
| Per-project | `/srv/projects/<n>/mpd.env` | seeded by `project-create.sh`, mutated by `mpd configure <project> KEY=VALUE` and manual edit | project-scoped truth; sourced 4th, wins |
| Per-type seed | `assets/runtimes/<rt>/project_types/<type>/mpd-template.env` | project type, in repo (read-only) | NOT sourced — copied to `/srv/projects/<n>/mpd.env` at `create` time |

**Seeding** (one-shot, at create time): at `mpd create <project>`, the
project type's `project-create.sh` copies `mpd-template.env` to the project
as `mpd.env` *only if absent* — pre-existing mpd.env (e.g. from a clone or
hand-staged) is sacred. The seed file is not the source of defaults; it's a
starting point for the user's own per-project overrides, with commented
hints for discoverability.

**Sourcing order at runtime** (in
`assets/runtime-base/lib/source-mpd-env.sh`):

1. runtime defaults (`mpd-defaults.env`)
2. type defaults (`mpd-defaults.env`)
3. `~/.mpd/mpd-user.env`
4. project `mpd.env`

Runtime + type are read from `/srv/meta/<n>/project.json` (written by
Swift's `writeProjectMeta`) using `jq`. Bash "last assignment wins" gives
the right semantics — each layer overrides earlier ones, and explicit
`KEY=""` blocks fall-through:

| layer-1 (runtime) | layer-2 (type) | layer-3 (user) | layer-4 (project) | result |
|---|---|---|---|---|
| `MPD_PHP_VERSION=8.3` | (absent) | (absent) | (absent) | `8.3` |
| `MPD_PHP_VERSION=8.3` | `MPD_PHP_VERSION=8.2` | (absent) | (absent) | `8.2` (type override) |
| `MPD_PHP_VERSION=8.3` | `MPD_PHP_VERSION=8.2` | `MPD_PHP_VERSION=8.4` | (absent) | `8.4` (user override) |
| `MPD_PHP_VERSION=8.3` | (absent) | (absent) | `MPD_PHP_VERSION=8.5` | `8.5` (project override) |

`MPD_DB` is the same: a project type that doesn't use a DB ships `MPD_DB=""`
in its `mpd-template.env` (astro, bare) so the seeded project file blocks
any `MPD_DB=...` the developer set in mpd-user.env; types that do ship a
sensible default (`MPD_DB=postgres:latest` for moodle).

**How `mpd-user.env` reaches the runtime:** the host file `~/.mpd/mpd-user.env`
is *synced* into the data volume at `/srv/personal/mpd-user.env` by
`Mpd.Core.State.syncBindMountFiles()` on every `mpd --setup` / `mpd --start`
(libkrun virtiofs has multi-second cache lag on bind-mounts of
freshly-created paths, so routing through the volume sidesteps that).
`bootstrap.sh` creates a symlink at `/home/<user>/mpd-user.env`
pointing at the volume copy, so `$HOME/mpd-user.env` resolves correctly inside
every runtime. Edit on the host, run `mpd --start` to re-sync.

**Naming convention:**

- `MPD_<RUNTIME>_<TYPE>_<KEY>` — project-type-specific knobs
  (`MPD_PHP_MOODLE_BEHAT`, `MPD_NODE_ASTRO_PORT`).
- `MPD_<RUNTIME>_<KEY>` — runtime-wide, applies to every type on that
  runtime (`MPD_PHP_VERSION`, `MPD_PHP_XDEBUG_MODE`).
- `MPD_<KEY>` — global mpd infra (none currently in active use; the
  former `MPD_DNS_UPSTREAM` is gone — dnsmasq now bind-mounts the host's
  systemd-resolved upstream and follows whatever the host has configured).
- **Reserved keys:** `MPD_DB` is owned by Swift's `Mpd.Runtime.DB.parseTag`
  (engine whitelist + version regex); other reserved keys go in the same map
  in `ProjectOperations.sanitiseEnvValue` as they're added.

**CLI surface for editing:** `mpd configure <project> KEY=VALUE [...]`
parses positional pairs matching `^MPD_[A-Z0-9_]+=.*$`, sanitises in Swift
(reserved-key map for strict validators, otherwise a generic safe-charset
check that blocks shell metacharacters), and rewrites the corresponding line
in `/srv/projects/<n>/mpd.env` via
`assets/runtime-base/tools/set-mpd-env`. Empty value deletes the line.
After mutations are applied, the project type's `configure.sh` sources the
layered env, generates config files, and emits resolved values into
`/srv/meta/<n>/effective.json` (where Swift reads `dbTag` to provision the
DB container).

## 9) Platform identity: conf/platform.env

`mpd` records the host context — which kind of setup this is, what the
laptop's OS is, and where the VM lives — in `~/Developer/mpd/conf/platform.env`.
Sibling to `caroot/`, `service/`, `wireguard/`. Lives under `conf/` so it
**survives `mpd --uninstall`** (which wipes `~/.mpd/`).

```
MPD_PLATFORM=desktop | macos-utm | generic-vm
MPD_CLIENT_OS=macos | debian | fedora | windows
MPD_VM_IP=<ip>                  # empty for desktop
MPD_INSTANCE_SUFFIX=<-suffix>   # e.g. "-161"; empty for the unsuffixed instance
```

`MPD_INSTANCE_SUFFIX` is the disambiguator for concurrent VMs / Podman
machines. Auto-derived at `mpd --setup` from the host name (`mpd-machine-<X>`
on the VM, or `mpd-desktop-<X>` on macOS), with the leading dash included
(or empty when there's no suffix). Used as the hostname suffix on runtime
**pods** (`mpd-runtime-<rt>-<X>`), so SSH'ing into `<rt>.runtime.mpd.test`
gives a bash prompt that makes the instance unambiguous. DNS names are
unaffected — they still resolve by IP via dnsmasq. Hand-edit to override;
the next `mpd --setup` will overwrite back to the auto-derived value.

`Platform.write` preserves any other `MPD_*` keys it doesn't manage
(`MPD_NETWORK_*` written by `provision-vm.sh`, etc.) so bootstrap scripts
and Platform can share the same file without clobbering each other.

**Writers:**

| Path | Writer | Values | Behavior |
|---|---|---|---|
| `mpd-desktop` | `Mpd.Core.Platform.ensureWritten(...)` from `DesktopActionSetup` | `desktop`, `macos`, `""` | bootstrap on first `mpd --setup`; no prompt |
| `mpd-machine` via UTM | `mpd-machine/platforms/macos-utm/create-vm.sh` (over SSH) | `macos-utm`, `macos`, `${VM_IP}` | written before `mpd --setup` runs in the VM |
| `mpd-machine` via generic VM | `mpd-machine/platforms/generic-vm/provision-vm.sh` | `generic-vm` + interactive prompt for `MPD_CLIENT_OS` and `MPD_VM_IP` | prompts at the very start of the user phase; idempotent (skips if all keys present) |

**Reader:** `Mpd.Core.Platform.load()` (Swift). Throws with a fix-it message
when missing, pointing at the matching bootstrap script. `MachineActionSetup`
reads it early so `MachineClientRecipe` can drive correct laptop-side recipes
(route, DNS resolver, optional CA trust) without `hostname -I` heuristics.
`mpd --setup-info` consumes the same values to regenerate the recipe on
demand.

**Why under `conf/` and not `~/.mpd/`:** the platform identity is part of
the persistent host setup — the same answers should apply across multiple
`mpd --setup` / `mpd --uninstall` cycles. `~/.mpd/` is state cache; `conf/`
is durable config (CA, certs, etc.).

## 10) Backup persistence

Goal: Moodle-style project backups (dataroot tar + DB dump produced by a
shell script) have one well-defined path off the data volume, identical
across modes.

`/srv/backups` is a subdirectory of the `mpd-data-volume` data volume.
Every container that mounts the volume — runtime pods, the fileaccess
service, etc. — sees the same content there. There is no host bind-mount
on either mode; the directory lives entirely inside the volume.

Read/write contract:

- **Runtime backup tools write here.** Project-type-specific tools
  (e.g. the planned `mdl-backup` under
  `assets/runtimes/php/project_types/moodle/tools/`) tar dataroot +
  DB dumps into `/srv/backups/` from inside the runtime. Backup is
  currently a Moodle-only concern; other project types keep state in
  the source tree (so `git` is their backup mechanism).
- **Fileaccess is the exit/entry point.** From the dev's laptop:
  `scp fileaccess.service.mpd.test:/srv/backups/<file> .` pulls a backup
  off; reverse direction stages a restore. The `mpd-service-fileaccess`
  container drops interactive ssh sessions into `/srv/backups/` so the
  human-facing path is one `cd` away.
- Authentication: pubkey-only. fileaccess reuses the user's existing
  `~/.ssh/authorized_keys`, so the laptop's SSH key already works.

Wipe contract:

- `podman volume rm mpd-data-volume` (or anything that wipes the Podman
  machine VM on Desktop, or the whole VM on Machine) deletes
  `/srv/backups/` along with everything else on the volume.
- Before wiping, pull anything you want to keep via fileaccess.
- This is intentional: fileaccess is the single transit point, so there's
  exactly one place to remember.

Cross-mode symmetry:

- Identical behavior on `mpd-desktop` and `mpd-machine` — same path, same
  write semantics, same exit point. No `#if os(...)` branches in the
  mount layout.
- No reliance on Podman Desktop's `$HOME` auto-mount or VM-host filesystem
  routing. The data volume is the single source of truth; fileaccess SSH
  is the single transport.

## 11) Networking, DNS, and TLS (Summary)

`mpd-desktop`:

- Uses WireGuard bootstrap to reach internal container network.
- Uses dnsmasq for `*.mpd.test` development DNS behavior.
- Uses project/service certificates signed by local `mpd` CA.

`mpd-machine` (current phase):

- VM-first networking model. The laptop reaches containers via a plain static
  route to `10.163.0.0/24` through the VM — no WireGuard tunnel.
- User-provided VM IP; per-OS laptop client recipes (route + DNS resolver +
  optional CA trust) are printed by `mpd --setup`.

Always-on infra services (both modes, except where noted):

- `dnsmasq` — DNS for `*.mpd.test`
- `portal` — read-only status site at `https://mpd.test/`
- `adminer` — DB management UI at `https://adminer.service.mpd.test/`
- `fileaccess` — `podman exec` target for volume tool ops, plus pubkey-only
  ssh/scp at `fileaccess.service.mpd.test`, the single transit point for
  project backups (`/srv/backups/` is a data-volume subdirectory)
- `wireguard` — mpd-desktop only

Per-runtime sidecars (attached to the runtime pod, not global):

- Caddy frontdoor — terminates TLS for project URLs and routes per-URL by
  `kind` and `backend` declared in each project's `urls.json`. Always-on for
  any runtime.
- `mailpit` — declared by PHP runtime defaults. **One instance per runtime**,
  shared by all projects on it (the SMTP black hole is per-pod). Canonical
  UI at `https://mail.<runtime>.mpd.test/`; per-project shortcut URLs
  `https://mail.<project>.mpd.test/` 302-redirect to the canonical with
  `?q=<project>.mpd.test`, so the user lands on a filtered view of the
  shared inbox. Runtime-level URL meta lives at
  `/srv/meta/_runtime-<rt>/` (a pseudo-project that flows through the same
  Caddy/cert/dnsmasq plumbing as real projects).
- `selenium` — pulled in when any project on the runtime has a URL with
  `kind: behat`.
- `valkey` — wired but not currently triggered.

Project URLs are project-type-driven (via `configure.sh` writing
`/srv/meta/<project>/urls.json`) and surfaced via the frontdoor sidecar — the
control-plane Swift code never hard-codes per-runtime URL shapes.

### Laptop-side split DNS (Windows note)

macOS (`/etc/resolver/mpd.test`) and Linux (`systemd-resolved` drop-in) handle
split DNS natively, so `mpd --setup` prints a one-line recipe and is done.

Windows is the awkward case. The built-in NRPT mechanism
(`Add-DnsClientNrptRule`) works for most queries but is bypassed by some
clients (notably Chromium's async resolver) and interacts poorly with
corporate VPN clients. The recommended fallback is to install a small
local DNS forwarder on the laptop, point the system resolver at `127.0.0.1`,
and let the forwarder split queries by domain (`*.mpd.test → 10.163.0.3`,
everything else → system upstream).

**Recommended tool: Acrylic DNS Proxy** — Windows-only, MSI installer with
tray icon, one-file config. This is the established precedent on Windows:
Laravel Valet for Windows (the `cretueusebiu/valet-windows` port and its
descendants) ships Acrylic and configures it to resolve `*.test → 127.0.0.1`,
mirroring what macOS Valet does with `/etc/resolver/`. So the split-DNS story
is symmetric: macOS uses the OS-native `/etc/resolver/<tld>` mechanism (which
Apple's own [`container`](https://github.com/apple/container) tool also uses),
and Windows uses Acrylic because the OS has no native equivalent — both are
the convention rather than a mpd-specific choice. Alternatives considered:
`dnscrypt-proxy` (cross-platform, but its "encrypted DNS" framing confuses
non-privacy users) and Deadwood from the MaraDNS suite (works, but obscure on
Windows). We recommend Acrylic for the intended audience; the others are fine
for users who already know them.

See detailed docs:

- `desktop/NETWORKING.md`, `desktop/SECURITY.md`
- `machine/NETWORKING.md`, `machine/SECURITY.md`

## 12) Repository Layer Map

- `mpd/mpd/CLI/` — command handlers, routing, status rendering
- `mpd/mpd/Environment/Desktop/` — macOS + Podman Desktop integration
- `mpd/mpd/Environment/Machine/` — machine-mode integration
- `mpd/mpd/Runtime/` — runtime/project orchestration and records
- `mpd/mpd/Service/` — service lifecycle control (`Mpd.Service.*`)
- `mpd/mpd/Core/` — core config/state/assets/data-volume logic
- `mpd/assets/` — runtime/type/service scripts/config/templates
- `docs/` — behavioral and architecture contracts

## 13) Contributor Change Map

If you change:

- CLI behavior: update `docs/CLI_BEHAVIOR.md`
- Runtime/project behavior: update `assets/runtimes/...` and matching docs
- Networking/TLS/DNS behavior: update networking/security docs for affected mode
- State shape or mutation behavior: update this file and relevant state docs/comments

## 14) Non-Goals (Current)

- Multi-tenant isolation or production hardening
- Binary distribution via git repository

## 15) Related Docs

- `README.md`
- `docs/README.md`
- `docs/CLI_BEHAVIOR.md`
- `docs/desktop/README.md`
- `docs/machine/README.md`
- `docs/VISION.md`
- `docs/ROADMAP.md`
- `AGENTS.md` — practical authoring guidance for verbs and tools (§"Authoring verbs and tools")
