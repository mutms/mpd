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
  - `state/` — operational state: projects.json, runtimes/, dns/, etc.

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
- `--web` — run the status page in the foreground on `127.0.0.1:8099`.
  Long-running, unlike every other flag here: the process *is* the
  service. Started by the `mpd-web.service` user unit, which
  `mpd --vm-setup` writes, enables and **restarts** on every run — so a
  template change reaches the browser with `make install && mpd --vm-setup`.
  Loopback only; caddy on the VM terminates TLS in front of it.
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

Among the per-user files it maintains, `--vm-setup` writes a marked block
into the dev user's `~/.ssh/config` giving every runtime in the assets
tree a short alias — `ssh mpd-<NNN>-php`, or `ssh php` — since DNS
carries only the fully-qualified name. The block is regenerated on every
run; content outside the markers is preserved. See
[`USAGE.md`](USAGE.md#ssh-into-the-runtime).

It also installs `mpd-control.service` (`mpd --control`), the daemon that
serves project commands sent from inside runtime containers. Restarted on
every run, like `mpd-web.service`, and for a sharper reason: it carries
the guard deciding what a runtime may ask for, so a daemon on the previous
binary would enforce the previous rules.

### Running `mpd` inside a runtime

The same binary behaves differently depending on where it runs. Inside a
runtime container (detected via `/etc/mpd/runtime`) it is a client: it
forwards the argv, the working directory and its own stdin/stdout/stderr
descriptors to the VM, and exits with the status of the mpd that ran
there. Output, colour, TTY behaviour and interactive prompts are the
caller's, because the process on the VM writes to the caller's terminal
directly rather than through a relay.

Only project verbs are accepted — `create`, `configure`, `start`, `stop`,
`reset`, `delete`, `show`, `help` — and only against projects belonging to
the calling runtime. `run` and every global flag are refused with a message
naming what to use instead. `version` is answered locally, since it
describes the binary being asked and `/opt/mpd` is the same checkout on
both sides.

Disable with `MPD_RUNTIME_CONTROL=off` in `/var/lib/mpd/env/mpd-vm.env`;
it is read per request, so no restart is needed. Full model in
[`SECURITY.md`](SECURITY.md#the-runtime-control-socket), workflow in
[`USAGE.md`](USAGE.md#mpd-from-inside-the-runtime).

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

`reset` does infer, despite being destructive, because that reason does not
apply to it: it keeps the source tree, so the inferred project is still a
directory that exists afterwards. The typed-name confirmation is what
guards it.

Project-focused universal verbs (recommended daily surface):
- `create` is inert beyond scaffolding: accepts `--type`. It does not fetch any source — `/srv` is mounted on the VM, so cloning is ordinary shell (`git clone`, or `mudev clone <recipe>`) done before or after, with the developer's own credentials. Project-type `project-create.sh` seeds `/srv/projects/<project>/mpd.env` from the type's `mpd-template.env` (existing mpd.env preserved, so scaffolding a directory that already holds a source tree is safe). No DB is provisioned here; the project is registered with status `notConfigured`. Next step is `mpd configure`.
- `configure` takes any number of positional `KEY=VALUE` pairs matching `^MPD_[A-Z0-9_]+=.*$`. The control plane sanitises (reserved keys like `MPD_DB` get strict validation; others get a generic safe-charset check), then writes the line into `/srv/projects/<project>/mpd.env` (empty value deletes the line). Then runs the project-type `configure.sh` which sources the four-layer mpd.env (runtime defaults → type defaults → user-level → project) and emits `dbTag` / `urls` into `/srv/meta/<project>/{effective.json,urls.json}`. The control plane reads `dbTag`, re-sanitises, and provisions the DB container if non-empty (visible image-pull progress via `podman pull`, then `podman run -d`, then per-project DB creation). The full mpd.env model — file paths, sourcing order, sanitisation, reserved keys — is documented in [`ARCHITECTURE.md` §8 "Configuration model: mpd.env"](ARCHITECTURE.md#8-configuration-model-mpdenv).
- `start` re-reads `/srv/meta/<project>/urls.json` before it uses the URL
  list, because that file is the source of truth and the copy in
  `projects.json` is a cache only `configure` refreshes. The cert SANs and
  the DNS record are both composed from it, so starting from a stale copy
  would re-establish a project under names it no longer has. The refresh
  is silent — it needs no user action, so reporting it would be noise.
  What `start` will **not** do is re-run the project type's
  `configure.sh`: that resolves database tags and can create containers,
  which is too much for a daily verb to do unasked.
  It refuses on exactly one condition, the one it cannot repair itself: a
  project whose URLs all name another VM's zone (`/srv` restored or copied
  from another VM, or `MPD_VM_ID` changed since the project was
  configured). The error names both zones and says to run `mpd configure
  <project>`. Configuration judged unusable is never written into state.
  New invariants belong in `project.CheckConfigured`, and each should earn
  its place by the same test: if mpd can repair it, repair it instead of
  reporting it.
- `stop`
- `reset` — destroys everything the project generated and returns it to the
  state `create` left it in, keeping `/srv/projects/<project>/`. Drops the
  project's database (never the shared engine container, which keeps
  running), empties `/srv/data/<project>/`, removes `/srv/meta/<project>/`
  including the TLS certificate, and removes the DNS record. State goes
  back to exactly what `create` writes — name and type only — so the
  project is **not configured** and `start` refuses until `mpd configure`
  runs. That is deliberate on both counts: it is the honest description of
  a project with no database or dataroot, and it is what makes the
  switch-database flow work, since only `configure` reads the new
  `MPD_DB`. `config.php` survives (`configure.sh` writes it only when
  missing) while `config-mpd.php` is regenerated, which is how the engine
  changes underneath unchanged project code.
- `delete` — the one verb that always needs an explicit name

`reset` and `delete` both confirm by asking the caller to **type the
project name**, not `y/N`: `y` is the same keystroke regardless of which
project the prompt names, so it cannot distinguish the intended project
from a mistyped one. `--yes` skips the question for scripted use. The
other destructive flags (`--runtime-delete`, `--db-delete`) keep `y/N` —
they are VM-terminal-only and name infrastructure, not a developer's site.
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

- CLI is non-interactive by default except explicit interactive actions (shells, interactive verbs, confirmation prompts).
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
