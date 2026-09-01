# Hooks

API reference for mpd's hook system: typed Go `Event` values fire
at well-defined lifecycle points; bash scripts under
`hooks/<event-name>.d/` in the asset tree observe them.

Familiar shape: Debian's `cron.daily/`, systemd's `*.d/` drop-ins, git
hooks, NetworkManager's `dispatcher.d/`. `run-parts`-style.

## Vocabulary

Three nouns, no overlap:

- **Event** — Go struct value. The *thing that happens*. A verb handler
  constructs an event with typed context and fires it.
- **Hook** — bash script. The *observer*. Lives on disk under
  `hooks/<event-name>.d/`, runs where its audience is.
- **Audience** — where an event is delivered. Usually a container kind:
  the dispatcher fires into every running container of that kind. One
  audience is not a container at all — `AudienceVM` is the VM host
  itself, whose hooks run there as the dev user.

Events publish, hooks subscribe, audiences receive.

## Quick start

Add a hook script to the right asset directory, make it executable.
That's it — the dispatcher discovers it on the next event firing.

Example: graceful postgres shutdown when `mpd --vm-stop` runs:

```
assets/databases/postgres/hooks/mpd-pre-stop.d/90-graceful-stop.sh
```

```bash
#!/bin/bash
set -euo pipefail
echo "Sending SIGTERM (smart shutdown) to postgres..."
kill -TERM 1 2>/dev/null || true
```

Run `chmod +x` on the file; `mpd --vm-setup` reports whether it's
recognised. `mpd --vm-stop` will fire it.

## Resource lifecycle model

The hook engine assumes a specific persistence model — important for
understanding *when* events fire:

| Resource | Persisted lifecycle intent                                                                  | Live state (`current`)                |
|----------|---------------------------------------------------------------------------------------------|---------------------------------------|
| Project  | `Autostart` bool — true after `mpd start`, false after `mpd stop`                           | `Configured` joined with `Autostart`  |
| Database | `Autostart` bool — set by `mpd --db-start` / `--db-stop` (sticky across reboot)             | Computed from podman                  |
| Service  | `Autostart` bool — sticky boot intent set by `mpd --service-start` / `--service-stop`; a project's `MPD_REQUIRE_SERVICES` starts one on demand without it | Computed from podman |

Reconciliation: `mpd --vm-start` starts the databases
that should autostart, then restores every project whose `Autostart` is
set — including re-creating enabled service containers. Stopping mpd or
rebooting the VM preserves this intent; `mpd --vm-start` (or the systemd
`mpd.service` unit at boot) restores running state. See
`docs/architecture.md` §5 for the full state model.

A database's `Autostart` makes an explicitly-started engine come back on
its own after a reboot even when no project needs it. Beyond that, DB
lifecycle is driven by VM start (which starts the autostart
databases), project start (which re-creates or starts the database a
project needs, without touching its `Autostart` flag) and `mpd --gc`
(planned reclamation).

## Event catalogue

| Event                   | Audience            | Failure    | Timeout | Fires                                                                |
|-------------------------|---------------------|------------|---------|----------------------------------------------------------------------|
| `EventMpdPostSetup`     | `AudienceVM`        | `Continue` | 600 s   | once at the end of `mpd --vm-setup`, after everything is configured  |
| `EventMpdPreStop`       | `AudienceDatabase`  | `Continue` | 120 s   | once during `mpd --vm-stop`, before container teardown                  |
| `EventProjectPreStart`  | `AudienceDatabase`  | `Abort`    | 30 s    | per `mpd <p> start`, after the DB is up, before project-setup        |
| `EventProjectPreStop`   | `AudienceVM`        | `Continue` | 30 s    | per `mpd <p> stop`, while project is still running                   |
| `EventProjectPostStart` | `AudienceVM`        | `Continue` | 30 s    | per `mpd <p> start`, after project is recorded as running            |

### `EventMpdPostSetup`

Fires once at the end of `mpd --vm-setup`, after the dev stack and
every unit are configured. The moment "this VM is ready" becomes true —
which is what makes it the place to install something onto a VM that is
finally able to hold it.

- **Audience**: the VM.
- **Failure**: `Continue` — setup has already done its work; a
  developer's install script failing does not make the VM unconfigured.
- **Timeout**: 600 s. Setup hooks install things, and the shipped ones
  unpack multi-gigabyte IDE tarballs. A limit that cut one off mid-unpack
  would be worse than none, because the hook keeps running regardless
  (see "Limitations").
- **Env vars** (in addition to the standard set):

Shipped scripts:
- `assets/vm/hooks/mpd-post-setup.d/50-goland-install.sh`
- `assets/vm/hooks/mpd-post-setup.d/50-phpstorm-install.sh`

Both are one `exec` of the matching `*-install-app` tool, which no-ops
unless the developer has seeded a tarball through their mpd-virt overlay
*and* the IDE is not already installed. That is the pattern to copy:
**put the conditions in the tool, not in the hook** — a hook that fires
on every setup has to be cheap and silent when there is nothing to do.

A re-adopted or re-imaged VM gets its IDE backend back on the next
`--vm-setup`, without a download.

### `EventMpdPreStop`

Fires once during `mpd --vm-stop`, before any container teardown. DB
containers do graceful shutdown so the next start does not trigger
crash recovery.

- **Audience**: every running DB container on the host.
- **Failure**: `Continue` — a stop must always complete.
- **Timeout**: 120 s. Longer than the 30 s default because a database
  flushing pending IO legitimately takes a while.
- **Env vars**: just the standard set (no event-specific extras).

Shipped scripts:
- `assets/databases/postgres/hooks/mpd-pre-stop.d/90-graceful-stop.sh`
- `assets/databases/mariadb/hooks/mpd-pre-stop.d/90-graceful-stop.sh`
- `assets/databases/mysql/hooks/mpd-pre-stop.d/90-graceful-stop.sh`

All three send SIGTERM to PID 1 (the daemon) and exit immediately;
the kernel keeps the daemon running until smart shutdown completes,
then the container exits. Exit code is preserved; the dispatcher
reports `✓` if the SIGTERM signal was sent.

### `EventProjectPreStart`

Fires per project start, after the project's DB is ensured up but
before the project's `project-setup.sh` runs.

- **Audience**: the project's DB container only.
- **Failure**: `Abort` — pre-conditions should stop the verb if they
  fail so the user sees the problem immediately.
- **Timeout**: 30 s.
- **Env vars** (in addition to the standard set):
  - `MPD_HOOK_PROJECT` — project name
  - `MPD_HOOK_DB_ENGINE` — `postgres` / `mariadb` / `mysql`
  - `MPD_HOOK_DB_VERSION` — e.g. `latest`, `17`, `10.6`

Use cases (no scripts ship in v1; this is the fire point for asset
authors): per-project schema migrations, seed data, ensure-indexes,
custom DB roles.

### `EventProjectPreStop`

Fires per project stop, while the project is still serving.

- **Audience**: the VM.
- **Failure**: `Continue` — stops must always complete.
- **Timeout**: 30 s.
- **Env vars**: same as `EventProjectPreStart` (project, DB engine +
  version).

Use cases: drain in-flight work, flush per-project caches, graceful
shutdown of project-specific services.

Not to be confused with a project type's own `project-stop.sh`, which
`mpd stop` runs right after this event: hooks are the *developer's*
extension point and fire for every project, while `project-stop.sh` is
the *type's* and ships in the assets tree. Astro's does nothing but
print how to stop the dev server.

### `EventProjectPostStart`

Fires per project start, after the project is recorded as running and
its URL is live.

- **Audience**: the VM.
- **Failure**: `Continue` — the project is already started; a hook
  failure shouldn't undo that.
- **Timeout**: 30 s.
- **Env vars**: same as `EventProjectPreStart`.

Use cases: cache warming, log rotation prep, "first request"
synthetic warm-up.

## Asset layout

Hook scripts live under `hooks/<event-name>.d/` in the layer that
matches their audience kind:

```
assets/vm/hooks/<event>.d/                   # → VM audience (runs on the VM host)
assets/vm/hooks/<event>.d/              # → VM audience
assets/databases/<dbtype>/hooks/<event>.d/   # → database audience, per engine
assets/services/<svc>/hooks/<event>.d/       # → service audience (named service)
```

There is deliberately **no project-type layer** for VM-audience
events: `assets/vm/project_types/<type>/hooks/` is not scanned by
the dispatcher (a pinning test in `go/internal/hooks/` proves it), so
type-scoped behavior belongs in the type's scripts and tools, not in
hooks.

**Scripts must be named `*.sh`.** Anything else in the directory is
ignored — an editor backup (`10-foo.sh~`), a `.bak`, a stray `.swp`, or
a README would otherwise be handed to bash and run. The extension makes
"is this a hook?" answerable by looking. A hook that needs a compiled
helper execs it from a one-line wrapper.

Numeric prefixes (`10-`, `90-`) order scripts within a directory
(run-parts style). Cross-layer order: strictly by layer
then alphabetical within each.

**Pick the number by what the hook does to its container.** A hook that
terminates the service it runs in must sort last, because everything
after it fails against a container that is already shutting down — the
shipped `90-graceful-stop.sh` SIGTERMs the database engine, so
`mpd-pre-stop` hooks needing a live database belong in 10–89.

Note this differs from mpd's *tools*, which are deliberately
extensionless (`composer-install`, `node-install`): a tool is invoked
as a command on PATH, a hook is only ever fed to bash.

Event-name → directory name conversion: strip the `Event` prefix and
kebab-case the rest. Examples:
`EventMpdPreStop` → `mpd-pre-stop.d/`,
`EventProjectPreStart` → `project-pre-start.d/`.

## Hook script contract

A hook is a `*.sh` script in `hooks/<event-name>.d/`, invoked as
`bash <path>` — so the executable bit is not required, but the `.sh`
suffix is.

Where it runs, and as whom, follows the audience:

| Audience             | Runs                     | As                        |
|----------------------|--------------------------|---------------------------|
| `AudienceVM`         | on the VM host           | the dev user (the identity mpd itself runs as) |
| `AudienceVM`         | on the VM                | the dev user              |
| `AudienceDatabase` / `AudienceService` | in that container | the container's default user (root) |

The VM row is the privilege rule in `AGENTS.md`: that is
hosts with a dev user and passwordless sudo, so a script runs as that
user and `sudo`s the individual privileged commands. Database and service
containers are stock images with no such user — their hooks signal PID 1
and stay root.

A VM hook is the escape hatch for work that has no container to do it in:
installing onto the VM, touching a systemd unit, reading a path
containers never see. It has the VM's PATH, so `assets/vm/bin` tools are
reachable by bare name.

**Standard env vars** provided to every hook:

| Variable            | Description                                         |
|---------------------|-----------------------------------------------------|
| `MPD_HOOK_EVENT`    | Event name, e.g. `mpd-pre-stop`                     |
| `MPD_HOOK_REVISION` | Event revision number (default `1`)                 |
| `MPD_HOOK_VERB`     | mpd verb that fired the event, e.g. `start`, `stop` |

Plus event-specific `MPD_HOOK_*` variables — see the catalogue.

**Exit code**: `0` = success. Non-zero triggers the event's failure
mode (`Abort` or `Continue`).

**stdout / stderr**: captured by the dispatcher and printed to the
user. On failure, the full output is shown in the verb output. (A
`--verbose` streaming mode is planned but not yet shipped — see
"Limitations".)

**Idempotence**: hook scripts should be idempotent where possible.
The dispatcher is sequential within an audience (see "Limitations"),
so a hook can assume earlier hooks in its layer chain have already
completed.

## Go API

An event is a value of the `hooks.Event` struct, built by a constructor
function rather than declared as a type:

```go
// hooks.Event — one typed lifecycle moment.
type Event struct {
    Name       string                    // kebab-case, matches <name>.d
    Revision   int                       // surfaced as MPD_HOOK_REVISION
    Timeout    time.Duration             // zero means DefaultTimeout
    Audiences  []AudienceKind            // fired in declared order
    OnFailure  FailureMode               // Abort or Continue
    Env        map[string]string         // exported as MPD_HOOK_<KEY>
    Containers func(AudienceKind) []string // audience → container names
    ServiceName string                   // scopes AudienceService
}
```

Constants: audiences are `AudienceVM`, `AudienceDatabase`,
`AudienceService` and `AudienceVM`; failure modes are `Abort` and
`Continue`; timeouts default to `DefaultTimeout` (30 s), with
`StopTimeout` (120 s) for `mpd-pre-stop` and `SetupTimeout` (600 s) for
`mpd-post-setup`.

`Containers` is not consulted for `AudienceVM`: there is exactly one VM,
so the dispatcher resolves that audience to the fixed `VMTarget` ("vm",
which is also what the output labels print) and an event author cannot
get it wrong.

Add an event by writing a constructor in `events.go` that returns a
populated `Event`:

```go
// EventXxxYyy is the event name constant; the constructor fills in the
// audience, failure mode and env.
func XxxYyy(ctx context.Context, pr Project, p *podman.Client) Event {
    return Event{
        Name:      EventXxxYyy,
        Revision:  1,
        Audiences: []AudienceKind{AudienceVM},
        OnFailure: Continue,
        // Keys are prefixed with MPD_HOOK_ by the dispatcher.
        Env: map[string]string{"PROJECT": pr.Name},
        // Resolve the audience to the containers to fire into.
        Containers: func(a AudienceKind) []string { ... },
    }
}
```

Fire from a verb handler:

```go
err := hooks.Fire(ctx, out, hooks.XxxYyy(ctx, pr, p), "start", p)
```

`Fire` takes the context, the writer progress lines go to, the event,
the verb name that fired it, and the podman client. It returns a
non-nil error only when a failing hook aborted the verb.

The dispatcher:

1. Resolves the audience containers via the event's `Containers`
   function (running containers matching each audience kind, scoped to
   the project's DB for project-level events).
2. For each container, walks the layered hook directories, sorts by
   layer + numeric-prefix order, and execs each script via
   `podman exec` with `MPD_HOOK_*` env vars set.
3. Handles failures per `OnFailure`: `Abort` returns the error;
   `Continue` logs and proceeds.

The dispatcher and type definitions live in
`go/internal/hooks/hooks.go`. The event constructors are in
`go/internal/hooks/events.go`.

## Failure modes

- **`Abort`** — hook exit code `!= 0` aborts the firing verb. Use for
  pre-conditions where continuing would be incorrect (e.g. project
  start when its DB pre-flight failed — better to stop visibly than
  let the project come up half-broken).
- **`Continue`** — hook exit code `!= 0` is logged but the verb
  proceeds. Use for cleanup-style and post-state events: any `*PreStop`
  (the verb has to finish stopping), any `*PostStart` (the resource is
  already started), any `MpdPreStop` (mpd has to power off regardless).

## Diagnostics

The dispatcher knows the full Go event catalogue and can walk the
filesystem for installed hook scripts. Cross-referencing the two on
`mpd --vm-setup` produces three classes of warning:

- **Orphan hook (event removed)** — `hooks/<event>.d/` exists for an
  event that's no longer in the catalogue.
  → "Hook X for unknown event Y; remove or move."
- **Orphan hook (audience removed)** — event still exists but the
  layer's container kind is no longer in the event's audiences.
  → "Hook X subscribed to event Y, but Y no longer fires on this audience."
- **Revision bump** — event's `revision` increased since the last
  `mpd --vm-setup` run (tracked in `/var/lib/mpd/state/hooks-state.json`).
  → "Event X revised; review env-var contract for hooks under hooks/X.d/."

Diagnostics are warnings, never hard failures — orphan hooks just
don't fire. Users get a loud notice at upgrade time but mpd keeps
working.

## Systemd integration

`mpd --vm-setup` installs a user-level
`mpd.service` unit at `~/.config/systemd/user/mpd.service` that
brackets the VM lifecycle:

```ini
[Unit]
Description=mpd lifecycle (start on boot, graceful stop on shutdown)
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target suspend.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=-/opt/mpd/bin/mpd --vm-start
ExecStop=/opt/mpd/bin/mpd --vm-stop
TimeoutStartSec=300
TimeoutStopSec=180

[Install]
WantedBy=default.target
```

Plus `loginctl enable-linger <devuser>` so the user systemd manager
runs at boot and survives logout.

**At boot**: user systemd starts → `default.target` → `mpd.service`
ExecStart fires `mpd --vm-start`, which reconciles every
autostart project, and every enabled extra service back to live
containers (and starts the autostart databases). The dev user can SSH in
seconds later and find the env already up.

**At shutdown**: `shutdown -h now`, `poweroff`, `reboot`,
`mpd --vm-restart`, GNOME shutdown menu, and `virsh shutdown <vm>` all
trigger `mpd --vm-stop` via the unit's ExecStop. That fires
`EventMpdPreStop`, which lets DBs shut down gracefully so the next
boot doesn't trigger crash recovery.

The leading `-` on `ExecStart` makes start failures non-fatal — the
unit still goes active, so the ExecStop graceful-stop path is never
lost even if a previous boot's `mpd --vm-start` had a hiccup.

**Not covered**: hypervisor force-stop, hard reset, power loss.
Those bypass systemd entirely; postgres comes up doing crash recovery
on next start. Irreducible.

User unit, not system unit, because the privilege rule (see
`AGENTS.md`) forbids identity switching. mpd binary runs as the dev
user; user units run as that user automatically.

Manual cleanup (or VM removal) reverses both the unit install and the
linger enable.

## Limitations

What's deferred from v1, called out so hook authors aren't surprised:

- **Sequential execution within an audience.** The dispatcher loops
  over containers in serial. Two DB containers responding to
  `EventMpdPreStop` shut down one after another, not in parallel.
  Acceptable for a few containers; will revisit if total stop time
  becomes painful.
- **A timed-out hook keeps running inside its container.** mpd enforces
  the deadline by killing the `podman exec` client, which stops the hook
  blocking mpd — the point of the timeout — but does not signal the
  process inside the container. A runaway script keeps running there
  until it finishes or the container stops. Verified, not assumed.

  Deliberately not solved with a `pkill -f <script>` sweep: that means
  running pattern-matched kills as root inside a container to recover
  from a rare case, and the recovery mpd already has is blunter and
  safer — restart the affected unit, or the VM. Revisit only if a runaway hook
  turns out to be a real recurring problem rather than a theoretical one.

- **No `--verbose` streaming.** Hook stdout/stderr is captured and
  shown after-the-fact, not streamed. For debugging hangs, use
  `podman logs <container>` or shell into the container directly.

Adding any of these is purely an engine change — no event constructor
or hook script needs to be updated to pick up the improvement.

## Adding a new event

1. **Decide the audience and failure mode.** Audiences are
   `AudienceVM`, `AudienceDatabase`, `AudienceService`. Failure
   mode is `Abort` for pre-conditions, `Continue` for cleanup-style or
   post-state.
2. **Add the event name constant and a constructor** returning a
   `hooks.Event` in `go/internal/hooks/events.go` — environment-wide
   events are named `Mpd*`, project-scoped ones `Project*`,
   VM-scoped ones `Vm*`.
3. **Register in the catalogue.** Add a `CatalogueEntry` to
   `hooks.Catalogue()` in `go/internal/hooks/diagnose.go` so the
   diagnostic engine knows about it.
4. **Fire from the relevant verb handler.** Single line:
   `hooks.Fire(ctx, out, hooks.XxxYyy(...), "<verb>", p)`.
5. **`make install` + `make vet test`.** Build and checks stay green.
6. **Document.** Add a subsection in this file's "Event catalogue"
   matching the existing format (one-line summary, audience, failure
   mode, timeout, env vars, use cases).

The orphan + revision diagnostics make the catalogue safe to iterate
on: add events freely; deprecate by shrinking audiences (loud but
graceful); remove events when nothing subscribes (loud but graceful).
