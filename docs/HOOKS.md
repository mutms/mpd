# Hooks

> **Status:** v1 in trunk; acceptance test pending (the VM-reboot
> scenario below). Engine, four events, DB-side hook mount, diagnostics,
> and systemd shutdown integration are all wired. Polish items
> (parallel-in-audience execution, per-event timeout enforcement,
> `--verbose` streaming) are deferred and called out below.

mpd's lifecycle behavior is currently hardcoded in Swift: per-runtime
stop sequences, per-DB-type init, dnsmasq registration on project start,
and so on. This contradicts the asset-additive model the rest of mpd
follows. Hooks move that logic out of Swift and into bash scripts that
asset authors can drop into well-known directories.

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

## Why this exists

Two pain points motivate v1:

1. **Hardcoded per-runtime / per-DB lifecycle.** Stopping a `php` runtime
   needs a different ritual from a `node` runtime; provisioning a
   project's DB differs across postgres / mysql / mariadb. Today this is
   Swift code. Adding a new runtime or DB type means editing Swift,
   recompiling, re-symlinking — at odds with mpd's "drop assets in,
   restart" model everywhere else.

2. **Postgres recovery on next start after VM reboot.** When the
   mpd-machine VM is power-cycled (or even cleanly rebooted), DB
   containers come up doing crash recovery. Moodle's first request after
   resume can hit `Database connection failed` while recovery is in
   flight. Tracked as "Graceful shutdown / postgres recovery" in
   `docs/ROADMAP.md`. The hook system + systemd shutdown integration
   closes this directly.

## Resource lifecycle model

The shape of the persistence model the engine is built on:

| Resource | Persisted desired state? | When does it run? |
|---|---|---|
| Runtime  | Yes (start/stop is explicit user intent) | When state=started AND mpd is up |
| Project  | Yes (start/stop is explicit user intent) | When state=started AND its runtime is up |
| Database | **No** — demand-driven by runtime | Pre-warmed at runtime start for every project on the runtime (running OR stopped) |
| Service  | Always | Whenever mpd is up |

Databases are not first-class lifecycle citizens. Their lifecycle is
derived from runtime + project state: when a runtime starts, mpd
pre-warms every DB needed by any project on that runtime — including
stopped projects, so subsequent `mpd start <project>` never blocks on a
cold DB. Manual `mpd db-start` ensures-up but isn't recorded as intent.
DBs never auto-stop — `mpd --gc` (future) reclaims unused ones
explicitly. Devs poke at DBs after stopping projects; beginners use one
DB and never need optimization. Release-test machines that carry many
DB versions are kept on a separate mpd-machine by convention, so the
daily dev machine stays small.

## v1 scope

The engine plus four events.

### Engine features

- **Dispatcher** — Swift API to fire typed events; enumerates audience
  containers; invokes hook scripts via `podman exec`; aggregates output
  and exit codes.
- **Audience routing** — each event class declares which container
  kinds receive it; dispatcher delivers in parallel across containers,
  sequentially within a container's `<event>.d/` directory (numeric
  prefix order, run-parts style).
- **Typed env-var contract** — each `Event` class's instance fields
  produce `MPD_HOOK_*` variables; contract is documented per event.
- **Failure modes** — `.abort` (verb fails if any hook fails) and
  `.continue` (failure logged but verb proceeds). Declared per event.
- **Timeouts** — per event; SIGTERM, wait 5s, SIGKILL, then apply the
  failure mode.
- **Progress UX** — quiet default (spinner + container + elapsed); live
  stream with `--verbose`; full output dumped on failure.
- **Diagnostic engine** — on `mpd --setup`, walks hook directories,
  cross-references against the Event catalogue, warns on orphans
  (unknown events, removed audiences) and revision bumps.
- **Systemd integration** — installs a user-level systemd unit that
  runs `mpd --stop` on `poweroff.target` / `reboot.target` /
  `suspend.target`, so VM shutdown triggers graceful DB shutdown
  via hooks.

### v1 event catalogue

| Event | Audience | Failure | Timeout |
|---|---|---|---|
| `EventMpdPreStop`       | `[.database]` | `.continue` | 120s |
| `EventProjectPreStart`  | `[.database]` | `.abort`    | 30s  |
| `EventProjectPreStop`   | `[.runtime]`  | `.continue` | 30s  |
| `EventProjectPostStart` | `[.runtime]`  | `.continue` | 30s  |

**`EventMpdPreStop`** — fires once during `mpd --stop`, before any
container teardown. DB containers do graceful shutdown
(`pg_ctl stop -m smart`, `mysqladmin shutdown`). Closes the postgres
recovery item from `docs/ROADMAP.md`.

**`EventProjectPreStart`** — fires per-project-start, after the
runtime + DB are up but before project-setup runs. Hook authors can
apply per-project schema migrations, seed data, ensure indexes, etc.,
on a DB guaranteed to be reachable.

**`EventProjectPreStop`** — fires per-project-stop, before container
teardown. Runtime containers do graceful shutdown (php-fpm signal,
node SIGTERM). Migrates today's hardcoded Swift logic.

**`EventProjectPostStart`** — fires per-project-start, after the
runtime container is up and reachable. Runtime containers do
post-start tasks (cache warming, log prep, etc.). Migrates any
post-start logic currently in Swift into assets.

Why these four for v1: they cover **mpd-level lifecycle + parallel
fan-out** (`EventMpdPreStop`), **per-project events with non-obvious
audience** (`EventProjectPreStart` → DB), the **`.abort` vs `.continue`
distinction**, the **pre vs post phase distinction**, and they ship
two real wins on day one (graceful DB shutdown closes a known bug;
hardcoded runtime-stop logic moves to assets).

### v1 acceptance test

The VM-reboot scenario, exercises persistence + ensure-up + graceful
shutdown end-to-end:

1. Create three runtimes (`php`, `node`, `trixie`); stop `trixie`,
   leave the others running.
2. Create several projects across the runtimes, each using a different
   DB type (postgres, mysql, mariadb); stop a few.
3. Manually start a couple of unused DBs (no project demands them).
4. `mpd --stop` (triggers `EventMpdPreStop` → graceful DB shutdown).
5. Manually reboot the VM.
6. `mpd --start`.

Expected end state: same runtimes started (php + node, not trixie);
same projects started (the previously-started subset); only DBs needed
by running projects are up. The "extra" DBs from step 3 do not come
back — nothing demanded them.

Postgres comes up clean (no recovery), proving the systemd shutdown
integration worked end-to-end.

## Asset layout

Hooks live in `hooks/<event-name>.d/` under each layer that may
contribute. Layered, alphabetical within each layer:

```
assets/runtime-base/hooks/<event>.d/                          # every runtime
assets/runtimes/<rt>/hooks/<event>.d/                         # specific runtime
assets/runtimes/<rt>/project_types/<type>/hooks/<event>.d/    # type-specific
assets/databases/<dbtype>/hooks/<event>.d/                    # DB containers
assets/services/<svc>/hooks/<event>.d/                        # service containers
```

Numeric prefixes (`10-`, `90-`) order scripts within a directory
(run-parts style). Cross-layer order: strictly by layer
(base → runtime → type), then alphabetical within each.

Event-name → directory name: strip `Event` prefix, kebab-case.
`EventProjectPreStart` → `project-pre-start.d/`.

## Engine

### Swift API

```swift
protocol Event {
    static var name: String { get }              // auto-derived from type name
    static var revision: Int { get }             // default 1
    static var audiences: [Audience] { get }
    static var onFailure: FailureMode { get }
    static var timeout: TimeInterval { get }     // default 30s
    var env: [String: String] { get }            // typed → MPD_HOOK_*
}

enum Audience {
    case runtime              // project's runtime container, or all running runtimes for mpd-level events
    case database             // project's DB container, or all running DBs for mpd-level events
    case service(String)      // a named service container
}

enum FailureMode {
    case abort                // hook failure aborts the verb
    case `continue`           // hook failure logs but verb proceeds
}
```

Three phases possible per verb (`Pre` / `Action` / `Post`). v1 only uses
`Pre` and `Post`; the `Action` phase exists in the design for verbs whose
mid-execution checkpoint becomes useful (different audience, different
context vars). Add when needed.

Verbs fire via:

```swift
try await Mpd.Events.fire(EventProjectPreStart(
    project: name,
    runtime: runtime,
    db: dbType
))
```

### Hook script contract

A hook is an executable script in `hooks/<event-name>.d/`, run inside the
audience container as that container's default user.

Standard env vars provided to every hook:

- `MPD_HOOK_EVENT` — event name (e.g. `project-pre-start`)
- `MPD_HOOK_REVISION` — event revision number
- `MPD_HOOK_VERB` — the mpd verb that fired this (e.g. `start`, `stop`)

Plus event-specific `MPD_HOOK_*` variables documented per event in the
catalogue.

Exit code: 0 = success. Non-zero triggers the event's failure mode.

stdout/stderr: captured. Default UX shows a spinner and elapsed time.
`--verbose` streams output live. Failure dumps full output regardless.

### Audience routing

Within an event:

- **Across containers in an audience**: parallel. Independent containers
  shouldn't serialize each other (postgres + mariadb both in `.database`
  for `EventMpdPreStop` shut down in parallel).
- **Within a container's `<event>.d/`**: sequential, in numeric-prefix
  order. `10-foo.sh` before `90-bar.sh`.

Across layers (base / runtime / type), the dispatcher concatenates
hook lists strictly by layer order, then alphabetical within each.
A type-level hook can rely on base + runtime hooks having already run.

### Failure modes

- `.abort` — hook exit code != 0 fails the firing verb. Used for
  pre-conditions (`EventProjectPreStart`: if DB can't ensure-up,
  project start should fail clearly so the user sees it).
- `.continue` — hook exit code != 0 logs a warning but verb proceeds.
  Used for cleanup-style and post-state events (any `*PreStop`,
  `*PostStart`, `*PostStop`). You can't "fail to stop" — the verb
  has to finish.

### Timeouts

Per event class. SIGTERM at the limit; if still alive after 5s, SIGKILL.
Whatever the failure mode is then applies. Default 30s; long ops (DB
shutdown, big restores) override to higher (e.g. 120s for `EventMpdPreStop`).

### Progress UX

Default (quiet but live):

```
$ mpd --stop
Stopping mpd...
  pre-stop hooks                      ⠋ postgres-1 (12s)
  pre-stop hooks                      ✓ postgres-1 (47s)
  pre-stop hooks                      ✓ mariadb-1 (3s)
Stopping containers...                ✓
```

Spinner + audience-target + elapsed time. Dispatcher renders this from
state it already has (event name, container, start time) — hooks don't
need to emit any special protocol.

`mpd --verbose` streams hook stdout/stderr live, prefixed with
`[<container> <event-name>/<script>]`. For debugging hangs and writing
new hooks.

On failure: the failing hook's full captured output dumps to the
terminal regardless of verbosity. You always see what went wrong.

### Mount story (per container kind)

- **Runtime containers** — `/mnt/assets/runtimes/<rt>/...` already
  bind-mounted for tools. Hook scripts at `/mnt/assets/runtimes/<rt>/hooks/`
  are reachable for free; dispatcher invokes them via `podman exec`.
  Lowest cost — start here.
- **Database containers** — stock images today, no mpd assets mounted.
  Plumbing: add a read-only bind mount at `/mnt/mpd-hooks/` pointing at
  the layered hook trees the container should see.
- **Service containers** — same plumbing as database containers.

## Diagnostics

The dispatcher knows the full Swift event catalogue and can walk the
filesystem for installed hook scripts. Cross-referencing the two on
`mpd --setup` produces three classes of warning:

- **Orphan hook (event removed)** — `hooks/<event>.d/` exists for an
  event no longer in the catalogue.
  → "Hook X for unknown event Y; remove or move."
- **Orphan hook (audience removed)** — event still exists but the
  layer's container kind is no longer in the event's audiences.
  → "Hook X subscribed to event Y, but Y no longer fires on this audience."
- **Revision bump** — event's `revision` number increased since the
  last `mpd --setup` run (tracked in `~/.mpd/hooks-state.json`).
  → "Event X revised; review env-var contract for hooks under hooks/X.d/."

A standalone `mpd --check-hooks` runs the same diagnostic on demand.

Diagnostics are warnings, never hard failures — orphan hooks just don't
fire. Users get a loud notice at upgrade time but mpd keeps working.

## Systemd integration

`mpd --setup` (machine path, including sandbox) installs a user-level
systemd unit at `~/.config/systemd/user/mpd.service`:

```ini
[Unit]
Description=mpd graceful shutdown
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target suspend.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop=/usr/local/bin/mpd --stop

[Install]
WantedBy=default.target
```

Plus `loginctl enable-linger <devuser>` so the user systemd manager
survives logout.

Effect: `shutdown -h now`, `poweroff`, `reboot`, GNOME shutdown menu,
and `virsh shutdown <vm>` all trigger `mpd --stop` before the VM goes
down, which fires `EventMpdPreStop`, which lets DBs shut down gracefully.

What this doesn't cover: hypervisor force-stop, hard reset, power loss.
Those bypass systemd entirely; postgres comes up doing crash recovery
on next start. Irreducible — same as today.

Has to be a user unit, not a system unit, because the privilege rule
(see `AGENTS.md`) forbids identity switching (`sudo -u <user>`). mpd
binary runs as the dev user; user units run as the user automatically.

`mpd --uninstall` reverses both the unit install and the linger enable.

## Future trajectory

Discipline: add an `Event*` only when there's a concrete need. No
speculative events.

Likely additions as use cases land:
- `EventProject*` for create / configure / delete (project-type
  customization at lifecycle points)
- `EventRuntime*` for build / destroy (runtime build customization)
- `EventMpd*` symmetry — `EventMpdPreStart`, `EventMpdPostStart`,
  `EventMpdPostStop`
- More phase coverage on existing verbs (e.g. `EventProjectActionStart`
  if the mid-verb checkpoint becomes useful)
- New audiences added to existing events (additive, non-breaking — see
  Diagnostics)
- Service-container events if always-on services ever need lifecycle
  hooks

The orphan + revision diagnostics make the catalogue safe to iterate on:
add events freely; deprecate by shrinking audiences (loud but graceful);
remove events when nothing subscribes (loud but graceful).

The pattern stays the same forever: add an Event class, ship hook
scripts under the new `hooks/<event-name>.d/` directories, no engine
changes.
