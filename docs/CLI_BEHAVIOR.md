# CLI Behavior (Source of Truth)

Purpose: define expected CLI behavior for `mpd` operations.

Status note:
- this contract applies to both `mpd-desktop` and `mpd-machine` — the CLI surface is identical across modes.

Out of scope:
- lifecycle UX details (`--setup/--start/--stop/--uninstall`) beyond routing notes
- deep architecture internals outside this behavioral contract (see `ARCHITECTURE.md`)

## Directory contract

CLI behavior assumes fixed paths:

- `~/Developer/mpd/bin/` for built executable usage
- `~/Developer/mpd/conf/` for persistent CA + service cert material (plus WireGuard keys on mpd-desktop)
- `~/.mpd/` for state/cache only

Project backups live inside the data volume at `/srv/backups/`, accessed
from the laptop via fileaccess SSH/scp; see
[ARCHITECTURE.md §10](ARCHITECTURE.md#10-backup-persistence).

## Contract level

This document is a behavioral contract for AI assistants and contributors implementing CLI changes.

If implementation and docs diverge, align code to this contract or update this file in the same change.

## Entry routing contract

From `mpd/mpd/main.swift`:

1. Bare `mpd` (no args) launches TUI.
2. If first token is positional (does not start with `-`), route to project command path:
   - `mpd <project> <verb> [args...]`
3. Otherwise, route to global flag command path.

Hard preconditions enforced before command execution:
- non-root execution only
- executable location check against expected build path

## Global command behavior

Global command dispatch is first-match, single-action per invocation.

Operational flags include:
- `--status` — context-aware status (text)
- `--setup` — idempotent first-run/reset; takes no argument (see below).
- `--start` / `--stop` — daily on/off; act on the active host adopted
  by `--setup`. `--start` reconciles `current` toward `requested` (see
  "Resource lifecycle model" in `docs/HOOKS.md`); `--stop` fires
  `EventMpdPreStop` hooks for graceful DB shutdown, then powers off
  (machine) or stops the Podman machine (desktop).
- `--restart` — graceful stop + restart. On mpd-machine, runs
  `sudo systemctl reboot` and lets the user-systemd `mpd.service` unit
  drive the chain (ExecStop=`mpd --stop` on shutdown, ExecStart=
  `mpd --start` on boot). On mpd-desktop, fires hooks then bounces the
  Podman machine; user runs `mpd --start` afterward to restore projects.
- `--check-hooks` — cross-reference `assets/.../hooks/<event>.d/`
  directories against the Swift `Event` catalogue and print warnings
  for orphans, removed audiences, and revision bumps. Also runs at the
  end of `mpd --setup`.
- `--uninstall` — partial teardown; preserves `~/Developer/mpd/conf/`.
- `--setup-info` — print the laptop-side setup recipe (plain text,
  pipeable from the laptop via `ssh user@vm "mpd --setup-info" > SETUP.txt`)
- runtime mutators: `--runtime-create`, `--runtime-start`, `--runtime-stop`, `--runtime-delete`, `--runtime`
- db mutators: `--db-create`, `--db-start`, `--db-stop`, `--db-delete`

Listing is **a verb**, not a flag — `mpd list [projects|runtimes|services|dbs]`
(default `projects`). Read-only entity queries; services are always-on
infra started by `--start`.

Operational preflight is not globally enforced before command dispatch.
Setup/start/stop paths perform their own environment-specific checks where needed.

### `--setup` adoption contract

`--setup` is mode-aware and takes no argument. It adopts the existing
host environment rather than provisioning one:

- **mpd-desktop** (macOS): the dev creates and starts a Podman machine
  named `mpd-desktop` (or `mpd-desktop-<suffix>` for concurrent variants;
  suffix is lowercase alphanumeric) in Podman Desktop. `mpd --setup`
  enumerates running Podman machines, requires exactly one matching the
  regex `^mpd-desktop(-[a-z0-9]+)?$`, and persists it as the active
  machine for `--start`/`--stop` to target. If no machine is running,
  more than one is running, or the running one isn't an mpd-desktop
  machine, `--setup` errors with a hint.
- **mpd-machine** (Linux VM): the VM itself is the host. `mpd --setup`
  validates the supported distro for the platform (Debian Trixie for
  the cloud-init platforms; Ubuntu 26.04 for sandbox), verifies
  `systemd-resolved` is active (a precondition the platform bootstrap
  is responsible for), and proceeds. The active-machine label is always
  pinned to `mpd-machine` regardless of the OS hostname (which may be
  `mpd-machine-<digits>` for concurrent cloud-init VMs or
  `mpd-machine-sandbox` for the sandbox platform).

Adoption tiers (mpd-desktop): if the running machine is the persisted
active one, `--setup` re-runs silently. If it's a different machine
that mpd has previously set up, the switch is silent. A brand-new
machine name prompts for confirmation before adoption. `--start` and
`--stop` always target the persisted active machine — manual machine
switching is by re-running `--setup` against the desired one.

### Fallback rule

If no known global flag path matches, status output is shown.

## Runtime-level workflow and CLI (before projects)

Runtimes are first-class and may be managed before any project exists.

Normal runtime-first IDE workflow (PHPStorm/VS Code remote):
1. create runtime (`--runtime-create=<name>`)
2. prepare code directory inside runtime
3. register/attach project from existing directory (project command path)

Note:
- IDEs may perform git clone for you over SSH into the selected runtime directory.
- mpd should then attach/register that existing directory as a project without requiring mpd-managed clone.

Project-first bootstrap workflow:
1. create project from git repo + branch + name (+ optional runtime)
2. default runtime is `php` when not specified
3. project type defaults to `moodle` when `--type` is not provided

Runtime-level global CLI (no project required):
- `mpd list runtimes`
- `--runtime-create=<name>`
- `--runtime-start=<name>`
- `--runtime-stop=<name>`
- `--runtime-delete=<name>`
- `--runtime=<name>` -> show full runtime status details

Contract intent:
- runtime lifecycle must be usable independently from project lifecycle
- project create path must support both "create from git" and "attach existing directory" workflows

## Runtime-specific verbs

1. runtime-level verbs (`assets/runtimes/<runtime>/verbs/*.json`)

## Project command behavior

Scope clarification:
- no-project commands use global flags (`mpd --...`)
- project commands always start with a project name (`mpd <project> ...`)

Project command routing contract:

- `mpd <project>` -> show project info
- `mpd create <project> [--type=<type>] ...` -> create flow (default type: `moodle`)
- `mpd help <project>` -> project/type/runtime verb help
- other verbs -> dispatch via `Mpd.Project.dispatch(...)`

For non-create project verbs, project must already exist.

## Universal project verbs

Meaning:
- these verbs are project-scoped (they are not available at no-project/global level)
- they apply across project types unless a runtime/type explicitly overrides behavior

Project-focused universal verbs (recommended daily surface):
- `create` is inert beyond clone+scaffold: accepts `--type`, `--git-repo`, `--git-branch`, `--git-depth`. `--git-depth=<n>` does a shallow clone (passed straight to `git clone --depth=`) — useful for big repos like Moodle. Caveat: shallow clones implicitly `--single-branch`, so cross-branch operations need `git fetch --unshallow` first. Project-type `project-create.sh` seeds `/srv/projects/<project>/mpd.env` from the type's `mpd-template.env` (existing mpd.env preserved). No DB is provisioned here; the project is registered with status `notConfigured`. Next step is `mpd configure <project>`.
- `configure` takes any number of positional `KEY=VALUE` pairs matching `^MPD_[A-Z0-9_]+=.*$`. Swift sanitises (reserved keys like `MPD_DB` get strict validation; others get a generic safe-charset check), then writes the line into `/srv/projects/<project>/mpd.env` (empty value deletes the line). Then runs the project-type `configure.sh` which sources the four-layer mpd.env (runtime defaults → type defaults → user-level → project) and emits `dbTag` / `urls` into `/srv/meta/<project>/{effective.json,urls.json}`. Swift reads `dbTag`, re-sanitises, and provisions the DB container if non-empty (visible image-pull progress via `podman pull`, then `podman run -d`, then per-project DB creation). The full mpd.env model — file paths, sourcing order, sanitisation, reserved keys — is documented in [`ARCHITECTURE.md` §8 "Configuration model: mpd.env"](ARCHITECTURE.md#8-configuration-model-mpdenv).
- `start`
- `stop`
- `delete`

## Project-type-specific operations are tools, not verbs

The verb set above is fixed and Swift-only. There is no host-side
asset-shipped-verb mechanism: project-type-specific operations
(`cache-purge`, `cron`, `upgrade`, `install` on Moodle; `rebuild`,
`upgrade` on Astro) live as project-type **tools** inside the runtime
container, on PATH after you SSH in. See the `mdl-*` / `astro-*`
tables in `docs/{desktop,machine}/USAGE.md` for the full set, and
[`ARCHITECTURE.md` §7](ARCHITECTURE.md#7-verbs-and-tools) for the
verb-vs-tool contract.

## PHP Runtime

PHP runtime configuration knobs (PHP version, Xdebug mode, Behat
toggles, Moodle-specific defaults) live with the project type that
needs them under `assets/runtimes/php/project_types/<type>/`. This
section is a placeholder for runtime-wide PHP knobs and will be filled
out as those stabilize.

## Behavioral invariants

- CLI is non-interactive by default except explicit interactive actions (TUI, shells, interactive verbs).
- Destructive operations require confirmation unless `--yes` is present.
- Error messages should be actionable and include next command when possible.
- Idempotent operations should return success when already in desired state.

## Operational implementation split

Implementation policy for operational commands:

1. Container actions via Podman are Swift-initiated (may escalate via `sudo` when required).
2. Infrastructure-altering actions may combine Swift orchestration with shell helpers.
3. Runtime provisioning and in-runtime operational behavior should prefer shell scripts in `assets/`.

This keeps control-plane orchestration in Swift while runtime specifics stay versionable and portable in assets.

Contributor targeting:
- light developers should prefer additive `assets/` extensions (new runtime/project type/verbs/scripts),
- service/networking/control-plane changes are Swift-level changes.

## Cross-mode correctness priorities

Both modes share these correctness priorities:
1. project/runtime/db/service dispatch correctness
2. state transitions and status/list consistency
3. help/completion consistency for implemented flags/verbs
