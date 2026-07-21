# CLI Behavior (Source of Truth)

Purpose: define expected CLI behavior for `mpd` operations.

Out of scope:
- lifecycle UX details (`--vm-setup/--vm-start/--vm-stop`) beyond routing notes
- deep architecture internals outside this behavioral contract (see `ARCHITECTURE.md`)

## Directory contract

CLI behavior assumes fixed paths:

- `/opt/mpd/` for the code checkout, assets, and built binary
- `/var/lib/mpd/` for state/cache and configuration:
  - `conf/` — CA + service cert, `platform.env` (PRIVATE)
  - `env/mpd-vm.env` — user-editable VM-wide env overrides (mounted into runtimes)
  - `state/` — operational state: projects.json, runtimes/, dnsmasq.d/, etc.

Project backups live inside the data volume at `/srv/backups/`, accessed
from the laptop with scp off the VM; see
[ARCHITECTURE.md §10](ARCHITECTURE.md#10-backup-persistence).

## Contract level

This document is a behavioral contract for AI assistants and contributors implementing CLI changes.

If implementation and docs diverge, align code to this contract or update this file in the same change.

## Entry routing contract

From `go/cmd/mpd/main.go`:

1. Bare `mpd` (no args, no flags) shows status.
2. If the first token is a project verb, route to the project command path:
   - `mpd <verb> <project> [args...]`
3. Otherwise, route to the global flag command path.

Hard preconditions enforced before command execution:
- non-root execution only
- executable location check against expected build path

## Global command behavior

Global command dispatch is first-match, single-action per invocation.

Operational flags include:
- `--vm-status` — context-aware status (text)
- `--vm-setup` — idempotent first-run/reset; takes no argument (see below).
- `--vm-start` / `--vm-stop` — daily on/off; act on the active host adopted
  by `--vm-setup`. `--vm-start` reconciles `current` toward `requested` (see
  "Resource lifecycle model" in `docs/HOOKS.md`); `--vm-stop` fires
  `EventMpdPreStop` hooks for graceful DB shutdown, then powers off.
- `--vm-restart` — graceful stop + restart. On mpd VM, runs
  `sudo systemctl reboot` and lets the user-systemd `mpd.service` unit
  drive the chain (ExecStop=`mpd --vm-stop` on shutdown, ExecStart=
  `mpd --vm-start` on boot). User runs `mpd --vm-start` afterward to restore projects.
- `--check-hooks` — cross-reference `assets/.../hooks/<event>.d/`
  directories against the Go `Event` catalogue and print warnings
  for orphans, removed audiences, and revision bumps. Also runs at the
  end of `mpd --vm-setup`.
- runtime mutators: `--runtime-create`, `--runtime-start`, `--runtime-stop`, `--runtime-delete`, `--runtime`
- db mutators: `--db-create`, `--db-start`, `--db-stop`, `--db-delete`
  - `--db-delete` removes the container **and its data** under
    `/srv/dbs/<databaseId>/`, matching `mpd delete <project>` (which
    removes DB, dataroot, source and config together). A DB container is
    shared by every project on that engine:version, so the prompt names
    the projects that will lose data; `--yes` skips it. Nothing else
    deletes that directory — `list dbs` enumerates containers, so a
    container-only delete would leave data no mpd command can see.

Listing is **a verb**, not a flag — `mpd list [projects|runtimes|services|dbs]`
(default `projects`). Read-only entity queries; services are always-on
infra started by `--vm-start`.

Operational preflight is not globally enforced before command dispatch.
Setup/start/stop paths perform their own environment-specific checks where needed.

### `--vm-setup` adoption contract

`--vm-setup` is mode-aware and takes no argument. It adopts the existing
host environment rather than provisioning one:

`mpd --vm-setup` validates the supported distro (Debian Trixie across every 
platform), verifies `systemd-resolved` is active (a precondition the
platform bootstrap is responsible for), and proceeds. The
active-machine label is always pinned to `mpd VM` regardless of
the OS hostname (which may be `mpd-<digits>` for concurrent
cloud-init VMs or `mpd-sandbox` for the sandbox platform).

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
- project commands always start with a verb, followed by the project name (`mpd <verb> <project> ...`)

Project command routing contract:

- `mpd show <project>` -> show project info
- `mpd create <project> [--type=<type>] ...` -> create flow (default type: `moodle`)
- `mpd help <project>` -> project/type/runtime verb help
- other verbs -> one cobra command per verb in `go/cmd/mpd/main.go`,
  handled by `cli.Project*` in `go/internal/cli/project.go`

For non-create project verbs, project must already exist.

## Universal project verbs

Meaning:
- these verbs are project-scoped (they are not available at no-project/global level)
- they apply across project types unless a runtime/type explicitly overrides behavior

**The project name is optional for every verb except `delete`.** Inside
`/srv/projects/<name>/` — or any subdirectory of it — the verb acts on
that project, so `mpd start` and `mpd start moodle45` are the same
command from the right directory. An explicit name always wins. `delete`
is excluded deliberately: it removes the source tree, so the inferred
answer would routinely be the directory the caller is standing in.

Project-focused universal verbs (recommended daily surface):
- `create` is inert beyond scaffolding: accepts `--type`. It does not fetch any source — `/srv` is mounted on the VM, so cloning is ordinary shell (`git clone`, or `mudev clone <recipe>`) done before or after, with the developer's own credentials. Project-type `project-create.sh` seeds `/srv/projects/<project>/mpd.env` from the type's `mpd-template.env` (existing mpd.env preserved, so scaffolding a directory that already holds a source tree is safe). No DB is provisioned here; the project is registered with status `notConfigured`. Next step is `mpd configure`.
- `configure` takes any number of positional `KEY=VALUE` pairs matching `^MPD_[A-Z0-9_]+=.*$`. The control plane sanitises (reserved keys like `MPD_DB` get strict validation; others get a generic safe-charset check), then writes the line into `/srv/projects/<project>/mpd.env` (empty value deletes the line). Then runs the project-type `configure.sh` which sources the four-layer mpd.env (runtime defaults → type defaults → user-level → project) and emits `dbTag` / `urls` into `/srv/meta/<project>/{effective.json,urls.json}`. The control plane reads `dbTag`, re-sanitises, and provisions the DB container if non-empty (visible image-pull progress via `podman pull`, then `podman run -d`, then per-project DB creation). The full mpd.env model — file paths, sourcing order, sanitisation, reserved keys — is documented in [`ARCHITECTURE.md` §8 "Configuration model: mpd.env"](ARCHITECTURE.md#8-configuration-model-mpdenv).
- `start`
- `stop`
- `delete` — the one verb that always needs an explicit name
- `run <command> [args...]` — runs a command inside the runtime that owns the current project, with the caller's working directory forwarded verbatim (`/srv` is the same path on the VM and in the container). The child's stdin, stdout, stderr and exit code are the caller's; a TTY is allocated only when stdin is one. The command runs through a login shell, so it sees exactly the PATH an interactive runtime session has — every project-type tool (`mdl-install`, `phpunit`, `composer`) resolves. Note the grammar: everything after `run` is the command, so this is the one verb whose second argument is not a project name.

## Project-type-specific operations are tools, not verbs

The verb set above is fixed and Go-only. There is no host-side
asset-shipped-verb mechanism: project-type-specific operations
(`cache-purge`, `cron`, `upgrade`, `install` on Moodle; `rebuild`,
`upgrade` on Astro) live as project-type **tools** inside the runtime
container, on PATH after you SSH in. See the `mdl-*` / `astro-*`
tables in `docs/USAGE.md` for the full set, and
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

1. Container actions via Podman are initiated by the Go control plane (may escalate via `sudo` when required).
2. Infrastructure-altering actions may combine Go orchestration with shell helpers.
3. Runtime provisioning and in-runtime operational behavior should prefer shell scripts in `assets/`.

This keeps control-plane orchestration in Go while runtime specifics stay versionable and portable in assets.

Contributor targeting:
- light developers should prefer additive `assets/` extensions (new runtime/project type/verbs/scripts),
- service/networking/control-plane changes are Go-level changes.

## Cross-mode correctness priorities

Both modes share these correctness priorities:
1. project/runtime/db/service dispatch correctness
2. state transitions and status/list consistency
3. help/completion consistency for implemented flags/verbs
