# CLI Behavior

Purpose: define expected CLI behavior for `mpd` operations.

Out of scope:
- lifecycle UX details (`--vm-setup/--vm-start/--vm-stop`) beyond routing notes
- deep architecture internals outside this behavioral contract (see `architecture.md`)

## Directory contract

CLI behavior assumes fixed paths:

- `/opt/mpd/` for the code checkout, assets, and built binary
- `/var/lib/mpd/` for state/cache and configuration:
  - `conf/` — CA + service cert (PRIVATE)
  - `env/vm.env` — the developer's own env, shared across their VMs, sourced into every shell
  - `state/` — operational state: projects.json, services.json, etc.

Backups live inside the data volume at `/srv/backups/`, accessed from
the laptop with scp off the VM; see
[architecture.md §10](architecture.md#10-backup-persistence).

## Contract level

This document is a behavioral reference for AI assistants and contributors implementing CLI changes.

It is kept in sync with the implementation: a change that alters CLI behavior updates this file in the same change.

## Entry routing contract

From `go/cmd/mpd/main.go`:

1. Bare `mpd` (no args, no flags) shows status.
2. If the first token is a project verb, route to the project command path:
   - `mpd <verb> <project> [args...]`
3. Otherwise, route to the global flag command path.

Non-root execution is policy, not an enforced precondition — see
[`security.md`](security.md#non-root-execution-policy).

## Global command behavior

Global command dispatch is first-match, single-action per invocation.

Operational flags include:
- `--vm-status` — context-aware status (text)
- `--vm-diag` — read-only health sweep. Opens by naming the running
  version and when this VM was last `--vm-upgrade`d, then probes
  certificates, DNS, subnet routing, portal TLS, the project frontdoor, the optional
  desktop/RDP layer, and every container that state says should be
  running. Exits non-zero if any check failed, so it works as a scripted
  gate. Distinct from
  `--vm-status`, which renders mpd's own state files: diag *probes*, which
  is what catches the failures that leave those files looking correct — a
  VPN capturing DNS, claiming the container subnet, or intercepting TLS.
- `--vm-setup` — idempotent first-run/reset; takes no argument (see below).
- `--vm-upgrade` — pull and rebuild mpd (plus mudev and the `/srv/extra`
  catalogues), then re-run `--vm-setup`. Refuses over uncommitted changes
  in `/opt/mpd`. See [`usage.md`](usage.md#updating-mpd).
- `--vm-start` / `--vm-stop` — daily on/off; act on the active host adopted
  by `--vm-setup`. `--vm-start` restores the autostart projects and
  databases (see "Resource lifecycle model" in `docs/hooks.md`);
  `--vm-stop` fires `EventMpdPreStop` hooks for graceful DB shutdown, then
  powers off.
- `--vm-restart` — graceful stop + restart. On mpd VM, runs
  `sudo systemctl reboot` and lets the user-systemd `mpd.service` unit
  drive the chain (ExecStop=`mpd --vm-stop` on shutdown, ExecStart=
  `mpd --vm-start` on boot), so projects come back without further commands.
- `--web` — run the status page in the foreground on `127.0.0.1:8099`.
  Long-running, unlike every other flag here: the process *is* the
  service. Started by the `mpd-web.service` user unit, which
  `mpd --vm-setup` writes, enables and **restarts** on every run — so a
  template change reaches the browser with `make install && mpd --vm-setup`.
  Loopback only; caddy on the VM terminates TLS in front of it.
- service mutators (`<name>` is one of the extras: mailpit, adminer,
  selenium; the sticky autostart intent persists in
  `/var/lib/mpd/state/services.json`). A project usually brings a service up by
  listing it in `MPD_REQUIRE_SERVICES` — mpd then ensures it on `mpd start`,
  like the project's database, without setting the sticky flag. These flags
  drive a service directly:
  - `--service-start=<name>` — start + make it autostart (restart policy
    plus a reconcile in `--vm-start`/`--vm-setup`).
  - `--service-stop=<name>` — stop + clear autostart; a project that
    requires it starts it again on its next `mpd start`.
  - `--service-uninstall=<name>` — remove the container, **keep** its
    data volume.
  - `--service-purge=<name>` — remove the container and the volume.
- db mutators: `--db-create`, `--db-start`, `--db-stop`, `--db-delete`
  - `--db-delete` removes the container **and its data** under
    `/srv/dbs/<databaseId>/`, matching `mpd delete <project>` (which
    removes DB, dataroot, source and config together). A DB container is
    shared by every project on that engine:version, so the prompt names
    the projects that will lose data; `--yes` skips it. Nothing else
    deletes that directory — `list dbs` enumerates containers, so a
    container-only delete would leave data no mpd command can see.

Listing is **a verb**, not a flag — `mpd list
[projects|services|infra|dbs|network]` (default `projects`).
Read-only entity queries. `services` lists the optional extra
containers only (with intent-aware status); `infra` lists the VM's
container plus the VM-integral systemd units (dnsmasq, the portal);
`network` prints this VM's addressing (id, zone, subnet, gateway).

Operational preflight is not globally enforced before command dispatch.
Setup/start/stop paths perform their own environment-specific checks where needed.

### `--vm-setup` adoption contract

`--vm-setup` is mode-aware and takes no argument. It adopts the existing
host environment rather than provisioning one:

`mpd --vm-setup` validates the supported distro (Debian Trixie across every
platform) and proceeds. Identity is derived from the hostname `mpd-<NNN>`
(ids 100..254 — the same on managed and sandbox VMs; see
[`architecture.md` §9](architecture.md#9-identity-the-hostname)).

`--vm-setup` converges the dev stack itself: it apt-installs the PHP
matrix, configures php.ini and the FPM pools, registers the `php`
dispatcher, fetches Composer and Node, and installs `mpd-caddy.service`
— the project frontdoor bound to `10.163.<NNN>.2`. There is no separate
provisioning flag: setup is the provisioner.

It **refuses** when a runtime container from the old layout still holds
`.2` on the bridge, and names mpd-virt's `upgrade/03-remove-runtime.sh`.
Removing it here would be migration logic in the shipped path, which mpd
deliberately carries none of.

### Fallback rule

If no known global flag path matches, status output is shown.

## VM-level workflow and CLI

The dev stack is infrastructure, provisioned by `mpd --vm-setup` and
carried by `--vm-start`/`--vm-stop` along with everything else. There is
no per-component mutator: re-running `--vm-setup` converges it.

The stack exists before any project does, so the IDE-first workflow
needs no extra step:
1. `mpd --vm-setup` has already provisioned it
2. prepare a code directory (IDEs may git clone for you over SSH —
   `ssh mpd-<NNN>`)
3. register/attach the existing directory as a project (project command
   path)

Project-first bootstrap workflow:
1. stage the source tree under `/srv/projects/<name>/` yourself
   (ordinary shell: `git clone`, `mudev clone`), then `mpd init`
2. project type defaults to `moodle` when `--type` is not provided
3. `mpd start <name>` configures and brings it up in one step

VM-level global CLI (no project required):
- `mpd list infra` — dnsmasq, the portal, and the project frontdoor

Contract intent:
- the dev stack is infrastructure, provisioned by setup — a project verb
  never creates or deletes it
- project init must attach an existing directory without requiring an
  mpd-managed clone — `init` never fetches source

## Project command behavior

Scope clarification:
- no-project commands use global flags (`mpd --...`)
- project commands always start with a verb, followed by the project name (`mpd <verb> <project> ...`)

Project command routing contract:

- `mpd status <project>` -> show project info. `--json` prints it as one
  JSON document instead — state, directories, zone, URLs, resolved
  settings and the database's engine/host/name/user. That is the
  interface tools use to ask about a project; they do not read
  `/srv/meta` themselves (see [`architecture.md` §7](architecture.md)).
- `mpd init <project> [--type=<type>] ...` -> scaffold flow (default type: `moodle`)
- `mpd help <project>` -> project/type verb help
- other verbs -> one cobra command per verb in `go/cmd/mpd/main.go`,
  handled by `cli.Project*` in `go/internal/cli/project.go`

For non-init project verbs, project must already exist.

## Universal project verbs

Meaning:
- these verbs are project-scoped (they are not available at no-project/global level)
- they apply across project types unless a type explicitly overrides behavior

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
- `init` is inert beyond scaffolding: accepts `--type`. It does not fetch any source — `/srv` is mounted on the VM, so cloning is ordinary shell (`git clone`, or `mudev clone <recipe>`) done before or after, with the developer's own credentials. Project-type `project-create.sh` seeds `/srv/projects/<project>/` from the type's `template/` directory — `mpd.env` for every type, plus whatever else it ships (Moodle adds `config.php` and `.phpstorm.meta.php/dml.php`) — and adds each to `.git/info/exclude`. Existing files are never overwritten, so scaffolding a directory that already holds a source tree is safe. `start` re-applies the same template, so a file added to it later reaches projects that already exist. No DB is provisioned here; the project is registered with status **not initialised**. Next step is `mpd start`.
- `start` **configures, then starts** — there is no separate `configure` verb, so a fresh `mpd init` is followed by a single `mpd start`. It always reconciles first, so an edit to `mpd.env` (by hand, or via the KEY=VALUE args below) is picked up on the next start with nothing else to run. It is **idempotent** (re-running always re-does the whole configure+start) and **fail-safe**: the project is recorded as **started** only after every step succeeds, and as **stopped** if any step fails — a half-start is never shown running.
  - **Configure step.** Takes any number of positional `KEY=VALUE` pairs matching `^MPD_[A-Z0-9_]+=.*$` (`mpd start <project> MPD_DB=postgres:18`). The control plane sanitises (reserved keys like `MPD_DB` get strict validation; others get a generic safe-charset check), then writes the line into `/srv/projects/<project>/mpd.env` in place, keeping the key under its own comment block (empty value comments the line out, unsetting the key). Then runs the project-type `configure.sh` which sources the layered mpd.env (developer defaults → type defaults → project) and emits `dbTag` / `urls` into `/srv/meta/<project>/{effective.json,urls.json}`. The control plane reads `dbTag`, re-sanitises, and provisions the DB container if non-empty (visible image-pull progress via `podman pull`, then `podman run -d`, then per-project DB creation). The full mpd.env model — file paths, sourcing order, sanitisation, reserved keys — is documented in [`architecture.md` §8 "Configuration model: mpd.env"](architecture.md#8-configuration-model-mpdenv). The configure step is also what makes the project **addressable**: it writes the vhost (`urls.json`, which the project caddy picks up), the TLS certificate, and the DNS record. Those survive a `stop`, so the URL keeps resolving and starts answering again as soon as something serves.
  - **Start step.** Carries the **server-side** lifecycle, and how much that is depends on the type — it runs its type's `project-setup.sh` (optional). For Moodle that is the real work: the database container is started if it is not running, and the per-project PHP-FPM pool is written and reloaded. For Astro the script only **prints** — the dev server is Astro's own (`npm run dev`, `astro dev --background`, `astro dev stop`), so mpd reports whether one is up and how to start it rather than running a competing one. A type opts out of the post-start URL wait with `"start": {"waitForURL": false}` in its `configuration.json`, which is what stops Astro spending 30s to warn about the expected state.
- `stop` carries the **server-side** lifecycle only, running its type's `project-stop.sh` (optional, best-effort — a stop cannot be allowed to fail). Idempotent: it always runs and records the project **stopped**, even on an already-stopped project. It does **not** touch addressability: the vhost, certificate and DNS record are the configure step's, and they survive a `stop` so the URL keeps resolving.
- `reset` — destroys everything the project generated and returns it to the
  state `init` left it in, keeping `/srv/projects/<project>/`. Drops the
  project's database (never the shared engine container, which keeps
  running), empties `/srv/data/<project>/`, removes `/srv/meta/<project>/`
  including the TLS certificate, and removes the DNS record. State goes
  back to exactly what `init` writes — name and type only — so the
  project reads **not initialised**; the next `mpd start` reconfigures it.
  That is deliberate on both counts: it is the honest description of a
  project with no database or dataroot, and it is what makes the
  switch-database flow work, since `start`'s configure step reads the new
  `MPD_DB`.
  `config.php` survives (`configure.sh` writes it only when missing) while
  `config-mpd.php` is regenerated, which is how the engine changes
  underneath unchanged project code.
- `delete` — the one verb that always needs an explicit name

`reset` and `delete` both confirm by asking the caller to **type the
project name**, not `y/N`: `y` is the same keystroke regardless of which
project the prompt names, so it cannot distinguish the intended project
from a mistyped one. `--yes` skips the question for scripted use. The
other destructive flags (`--db-delete`) keep `y/N` —
they are VM-terminal-only and name infrastructure, not a developer's site.

## Project-type-specific operations are tools, not verbs

The verb set above is fixed and Go-only. There is no host-side
asset-shipped-verb mechanism: project-type-specific operations
(`cache-purge`, `cron`, `upgrade`, `install` on Moodle) live as
project-type **tools** on PATH after you
SSH in. Astro ships none: its own `npm run dev` / `astro` commands are
the interface, and wrapping them would only add a second way to say the
same thing. See the `mdl-*` table in `docs/usage.md` for the full set, and
[`architecture.md` §7](architecture.md#7-verbs-and-tools) for the
verb-vs-tool contract.

## PHP configuration knobs

PHP configuration knobs (PHP version, Xdebug mode, Behat toggles,
Moodle-specific defaults) live with the project type that needs them
under `assets/vm/project_types/<type>/`. This section is a
placeholder for VM-wide PHP knobs and will be filled out as those
stabilize.

## Behavioral invariants

- CLI is non-interactive by default except explicit interactive actions (shells, interactive verbs, confirmation prompts).
- Destructive operations require confirmation unless `--yes` is present.
- Error messages should be actionable and include next command when possible.
- Idempotent operations should return success when already in desired state.

## Operational implementation split

Implementation policy for operational commands:

1. Container actions via Podman are initiated by the Go control plane (may escalate via `sudo` when required).
2. Infrastructure-altering actions may combine Go orchestration with shell helpers.
3. Dev-stack provisioning and project-type behavior should prefer shell scripts in `assets/`.

This keeps control-plane orchestration in Go while stack specifics stay versionable and portable in assets.

Contributor targeting:
- light developers should prefer additive `assets/` extensions (new project type/scripts),
- service/networking/control-plane changes are Go-level changes.

## Cross-mode correctness priorities

Both modes share these correctness priorities:
1. project/db/service dispatch correctness
2. state transitions and status/list consistency
3. help/completion consistency for implemented flags/verbs
