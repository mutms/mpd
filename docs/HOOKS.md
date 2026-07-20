# Hooks

API reference for mpd's hook system: typed Swift `Event` classes fire
at well-defined lifecycle points; bash scripts under
`hooks/<event-name>.d/` in container assets observe them.

Familiar shape: Debian's `cron.daily/`, systemd's `*.d/` drop-ins, git
hooks, NetworkManager's `dispatcher.d/`. `run-parts`-style.

## Vocabulary

Three nouns, no overlap:

- **Event** — Swift class. The *thing that happens*. A verb handler
  constructs an event with typed context and fires it.
- **Hook** — bash script. The *observer*. Lives on disk under
  `hooks/<event-name>.d/`, runs inside a container.
- **Audience** — list of container kinds an event reaches. Each event
  declares its audiences; the dispatcher delivers the event to every
  running container of those kinds.

Events publish, hooks subscribe, audiences receive.

## Quick start

Add a hook script to the right asset directory, make it executable.
That's it — the dispatcher discovers it on the next event firing.

Example: graceful postgres shutdown when `mpd --stop` runs:

```
assets/databases/postgres/hooks/mpd-pre-stop.d/10-graceful-stop.sh
```

```bash
#!/bin/bash
set -euo pipefail
echo "Sending SIGTERM (smart shutdown) to postgres..."
kill -TERM 1 2>/dev/null || true
```

Run `chmod +x` on the file, then `mpd --check-hooks` to confirm it's
recognised. `mpd --stop` will fire it.

## Resource lifecycle model

The hook engine assumes a specific persistence model — important for
understanding *when* events fire:

| Resource | Persisted intent (`requested`)                                 | Live state (`current`)                |
|----------|----------------------------------------------------------------|---------------------------------------|
| Runtime  | Yes — written only by `mpd --runtime-create/start/stop/delete` | Computed from podman every query      |
| Project  | Yes — written only by `mpd <p> create/start/stop/delete`       | Derived from runtime + project record |
| Database | **No** — emergent from runtime + project records               | Computed from podman                  |
| Service  | Always-on                                                      | Computed from podman                  |

Reconciliation: `mpd --start` walks `requested` and brings `current`
into agreement. Stopping mpd or rebooting the VM preserves `requested`;
`mpd --start` (or the systemd `mpd.service` unit at boot) restores
running state. See `docs/ARCHITECTURE.md` §5 for the full state model.

DBs and services have no `requested` because they're emergent. DB
lifecycle is driven by runtime start (which pre-warms every DB any
project on it might need) and `mpd --gc` (planned reclamation).

## Event catalogue

| Event                   | Audience      | Failure     | Timeout | Fires                                                                |
|-------------------------|---------------|-------------|---------|----------------------------------------------------------------------|
| `EventMpdPreStop`       | `[.database]` | `.continue` | 120 s   | once during `mpd --stop`, before container teardown                  |
| `EventProjectPreStart`  | `[.database]` | `.abort`    | 30 s    | per `mpd <p> start`, after runtime + DB are up, before project-setup |
| `EventProjectPreStop`   | `[.runtime]`  | `.continue` | 30 s    | per `mpd <p> stop`, while project is still running                   |
| `EventProjectPostStart` | `[.runtime]`  | `.continue` | 30 s    | per `mpd <p> start`, after project is recorded as running            |

### `EventMpdPreStop`

Fires once during `mpd --stop`, before any container teardown. DB
containers do graceful shutdown so the next start does not trigger
crash recovery.

- **Audience**: every running DB container on the host.
- **Failure**: `.continue` — a stop must always complete.
- **Timeout**: 120 s. Longer than the 30 s default because a database
  flushing pending IO legitimately takes a while.
- **Env vars**: just the standard set (no event-specific extras).

Shipped scripts:
- `assets/databases/postgres/hooks/mpd-pre-stop.d/10-graceful-stop.sh`
- `assets/databases/mariadb/hooks/mpd-pre-stop.d/10-graceful-stop.sh`
- `assets/databases/mysql/hooks/mpd-pre-stop.d/10-graceful-stop.sh`

All three send SIGTERM to PID 1 (the daemon) and exit immediately;
the kernel keeps the daemon running until smart shutdown completes,
then the container exits. Exit code is preserved; the dispatcher
reports `✓` if the SIGTERM signal was sent.

### `EventProjectPreStart`

Fires per project start, after the runtime + project's DB are
ensured up but before the project's `project-setup.sh` runs.

- **Audience**: the project's DB container only.
- **Failure**: `.abort` — pre-conditions should stop the verb if they
  fail so the user sees the problem immediately.
- **Timeout**: 30 s.
- **Env vars** (in addition to the standard set):
  - `MPD_HOOK_PROJECT` — project name
  - `MPD_HOOK_RUNTIME` — runtime name
  - `MPD_HOOK_DB_ENGINE` — `postgres` / `mariadb` / `mysql`
  - `MPD_HOOK_DB_VERSION` — e.g. `latest`, `17`, `10.6`

Use cases (no scripts ship in v1; this is the fire point for asset
authors): per-project schema migrations, seed data, ensure-indexes,
custom DB roles.

### `EventProjectPreStop`

Fires per project stop, while the project's runtime is still running.

- **Audience**: the project's runtime container only.
- **Failure**: `.continue` — stops must always complete.
- **Timeout**: 30 s.
- **Env vars**: same as `EventProjectPreStart` (project, runtime,
  DB engine + version).

Use cases: drain in-flight work, flush per-project caches, graceful
shutdown of project-specific services running inside the runtime.
Today's `sudo systemctl stop mpd-<project>` for project types with
`stopSystemd: true` is still a Swift code path; that one-liner is a
candidate to migrate into a project-type hook here.

### `EventProjectPostStart`

Fires per project start, after the project is recorded as running and
its URL is live.

- **Audience**: the project's runtime container only.
- **Failure**: `.continue` — the project is already started; a hook
  failure shouldn't undo that.
- **Timeout**: 30 s.
- **Env vars**: same as `EventProjectPreStart`.

Use cases: cache warming, log rotation prep, "first request"
synthetic warm-up.

## Asset layout

Hook scripts live under `hooks/<event-name>.d/` in the layer that
matches their audience kind:

```
assets/runtime-base/hooks/<event>.d/                         # → .runtime audience, every runtime
assets/runtimes/<rt>/hooks/<event>.d/                        # → .runtime audience, specific runtime
assets/runtimes/<rt>/project_types/<type>/hooks/<event>.d/   # → .runtime audience, type-scoped
assets/databases/<dbtype>/hooks/<event>.d/                   # → .database audience, per engine
assets/services/<svc>/hooks/<event>.d/                       # → .service(name) audience
```

**Scripts must be named `*.sh`.** Anything else in the directory is
ignored — an editor backup (`10-foo.sh~`), a `.bak`, a stray `.swp`, or
a README would otherwise be handed to bash and run. The extension makes
"is this a hook?" answerable by looking. A hook that needs a compiled
helper execs it from a one-line wrapper.

Numeric prefixes (`10-`, `90-`) order scripts within a directory
(run-parts style). Cross-layer order: strictly by layer
(base → runtime → type), then alphabetical within each.

Note this differs from mpd's *tools*, which are deliberately
extensionless (`composer-install`, `mudev-install`): a tool is invoked
as a command on PATH, a hook is only ever fed to bash.

Event-name → directory name conversion: strip the `Event` prefix and
kebab-case the rest. Examples:
`EventMpdPreStop` → `mpd-pre-stop.d/`,
`EventProjectPreStart` → `project-pre-start.d/`.

## Hook script contract

A hook is a `*.sh` script in `hooks/<event-name>.d/`, run inside the
audience container as that container's default user. mpd invokes it as
`bash <path>`, so the executable bit is not required — but the `.sh`
suffix is.

**Standard env vars** provided to every hook:

| Variable            | Description                                         |
|---------------------|-----------------------------------------------------|
| `MPD_HOOK_EVENT`    | Event name, e.g. `mpd-pre-stop`                     |
| `MPD_HOOK_REVISION` | Event revision number (default `1`)                 |
| `MPD_HOOK_VERB`     | mpd verb that fired the event, e.g. `start`, `stop` |

Plus event-specific `MPD_HOOK_*` variables — see the catalogue.

**Exit code**: `0` = success. Non-zero triggers the event's failure
mode (`.abort` or `.continue`).

**stdout / stderr**: captured by the dispatcher and printed to the
user. On failure, the full output is shown in the verb output. (A
`--verbose` streaming mode is planned but not yet shipped — see
"Limitations".)

**Idempotence**: hook scripts should be idempotent where possible.
The dispatcher is sequential within an audience (see "Limitations"),
so a hook can assume earlier hooks in its layer chain have already
completed.

## Swift API

Add an event by defining a struct that conforms to `Mpd.Hooks.Event`:

```swift
struct EventXxxYyy: Mpd.Hooks.Event {
    // Optional context — surfaced to hook scripts as MPD_HOOK_* vars.
    let project: String

    // Audience list. Multiple audiences = event delivered to each kind.
    static let audiences: [Mpd.Hooks.Audience] = [.runtime]

    // Failure mode — abort the firing verb, or continue past failures.
    static let onFailure: Mpd.Hooks.FailureMode = .continue

    // Optional overrides; sensible defaults via the protocol.
    // static let revision: Int = 1
    // static let timeout: TimeInterval = 30

    var env: [String: String] {
        // Map context fields to MPD_HOOK_<key> env vars.
        // The dispatcher prefixes with "MPD_HOOK_".
        ["PROJECT": project]
    }
}
```

Fire from a verb handler:

```swift
try Mpd.Hooks.fire(
    EventXxxYyy(project: name),
    verb: "start"
)
```

The dispatcher:

1. Resolves the audience containers (running containers matching each
   audience kind, scoped to the project's runtime/DB for project-level
   events).
2. For each container, walks the layered hook directories, sorts by
   layer + numeric-prefix order, and execs each script via
   `podman exec` with `MPD_HOOK_*` env vars set.
3. Handles failures per `onFailure`: `.abort` rethrows; `.continue`
   logs and proceeds.

The full type definitions live in `mpd/Hooks/Hooks.swift`. Concrete
event classes are in `mpd/Hooks/Event{Mpd,Project,Runtime}.swift`.

## Failure modes

- **`.abort`** — hook exit code `!= 0` aborts the firing verb. Use for
  pre-conditions where continuing would be incorrect (e.g. project
  start when its DB pre-flight failed — better to stop visibly than
  let the project come up half-broken).
- **`.continue`** — hook exit code `!= 0` is logged but the verb
  proceeds. Use for cleanup-style and post-state events: any `*PreStop`
  (the verb has to finish stopping), any `*PostStart` (the resource is
  already started), any `MpdPreStop` (mpd has to power off regardless).

## Diagnostics

The dispatcher knows the full Swift event catalogue and can walk the
filesystem for installed hook scripts. Cross-referencing the two on
`mpd --setup` (and on demand via `mpd --check-hooks`) produces three
classes of warning:

- **Orphan hook (event removed)** — `hooks/<event>.d/` exists for an
  event that's no longer in the catalogue.
  → "Hook X for unknown event Y; remove or move."
- **Orphan hook (audience removed)** — event still exists but the
  layer's container kind is no longer in the event's audiences.
  → "Hook X subscribed to event Y, but Y no longer fires on this audience."
- **Revision bump** — event's `revision` increased since the last
  `mpd --setup` run (tracked in `/var/lib/mpd/hooks-state.json`).
  → "Event X revised; review env-var contract for hooks under hooks/X.d/."

Diagnostics are warnings, never hard failures — orphan hooks just
don't fire. Users get a loud notice at upgrade time but mpd keeps
working.

## Systemd integration

`mpd --setup` (machine path, including sandbox) installs a user-level
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
ExecStart=-/home/<user>/Developer/mpd/bin/mpd --start
ExecStop=/home/<user>/Developer/mpd/bin/mpd --stop
TimeoutStartSec=300
TimeoutStopSec=180

[Install]
WantedBy=default.target
```

Plus `loginctl enable-linger <devuser>` so the user systemd manager
runs at boot and survives logout.

**At boot**: user systemd starts → `default.target` → `mpd.service`
ExecStart fires `mpd --start`, which reconciles every runtime + project
in `requested=running` state back to live containers (and pre-warms
their DBs). The dev user can SSH in seconds later and find the env
already up.

**At shutdown**: `shutdown -h now`, `poweroff`, `reboot`,
`mpd --restart`, GNOME shutdown menu, and `virsh shutdown <vm>` all
trigger `mpd --stop` via the unit's ExecStop. That fires
`EventMpdPreStop`, which lets DBs shut down gracefully so the next
boot doesn't trigger crash recovery.

The leading `-` on `ExecStart` makes start failures non-fatal — the
unit still goes active, so the ExecStop graceful-stop path is never
lost even if a previous boot's `mpd --start` had a hiccup.

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
  safer — restart the runtime, or the VM. Revisit only if a runaway hook
  turns out to be a real recurring problem rather than a theoretical one.

- **No `--verbose` streaming.** Hook stdout/stderr is captured and
  shown after-the-fact, not streamed. For debugging hangs, use
  `podman logs <container>` or shell into the container directly.

Adding any of these is purely an engine change — no event class or
hook script needs to be updated to pick up the improvement.

## Adding a new event

1. **Decide the audience and failure mode.** Audiences are
   `.runtime`, `.database`, `.service(name)`. Failure mode is `.abort`
   for pre-conditions, `.continue` for cleanup-style or post-state.
2. **Add a Swift struct** conforming to `Mpd.Hooks.Event` in the
   appropriate file under `mpd/Hooks/`:
   - `EventMpd.swift` for environment-wide events (`Mpd*`)
   - `EventProject.swift` for project-scoped events (`Project*`)
   - `EventRuntime.swift` for runtime-scoped events (`Runtime*`)
3. **Register in the catalogue.** Add `.init(EventXxx.self)` to
   `Mpd.Hooks.catalogue` in `mpd/Hooks/HooksDiagnostic.swift` so the
   diagnostic engine knows about it.
4. **Fire from the relevant verb handler.** Single line:
   `try Mpd.Hooks.fire(EventXxx(...), verb: "<verb>")`.
5. **Build + `make check`.** Boundary guards stay green.
6. **Document.** Add a subsection in this file's "Event catalogue"
   matching the existing format (one-line summary, audience, failure
   mode, timeout, env vars, use cases).

The orphan + revision diagnostics make the catalogue safe to iterate
on: add events freely; deprecate by shrinking audiences (loud but
graceful); remove events when nothing subscribes (loud but graceful).
