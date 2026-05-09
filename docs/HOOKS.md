# Hooks (concept sketch)

> **Status:** not implemented. This file captures the shape of an
> upcoming feature so the idea isn't lost between sessions. Detailed
> design — event names, env-var contract, failure semantics, ordering —
> comes when we plan implementation.

## Why

mpd's Swift control plane currently hardcodes lifecycle behavior per
runtime, project type, and database type:

- runtime stop sequences differ per runtime (PHP-FPM graceful, node
  signal handling, …) and the differences live in Swift
- DB integration (postgres / mysql / mariadb create-db, grant-perms,
  drop-db) lives in Swift
- adding a new project type or DB type means editing Swift, not just
  dropping assets — which contradicts the asset-additive model the
  rest of mpd already follows

A hook system removes this. Swift fires *named events* at well-defined
points in its verb handlers; tools, runtimes, project types, databases,
and services drop bash scripts into `<event>.d/` directories. Swift
just enumerates and executes them. Adding a new DB type or a
runtime-specific shutdown ritual becomes "drop a script into
`hooks/<event>.d/`" instead of "edit Swift, recompile, re-symlink."

Familiar pattern: Debian's `cron.daily/`, systemd's `*.d/` drop-ins,
git hooks, NetworkManager's `dispatcher.d/`. `run-parts`-style.

## Shape

**Trigger surface — Swift only.** Every hook fires because a Swift
verb handler reached a known point and called `Mpd.Hooks.fire(.event,
context: …)`. No systemd timers, no inotify, no daemon polling. Swift
controls when events fire, in what order, and how failures propagate.

**Three container kinds, one engine.** Same `<event>.d/` directory
pattern, same env-var contract, same dispatcher in Swift:

- **Runtime containers** (`php`, `node`, `trixie`, …) — project +
  runtime lifecycle events
- **Database containers** (`postgres`, `mysql`, `mariadb`, …) — DB
  lifecycle + per-project DB init/drop
- **Service containers** (`dnsmasq`, `portal`, `adminer`, `fileaccess`)
  — service setup / restart / health-check

A hook is always *inside* the container kind it pertains to. A
"postgres start hook" runs inside the postgres container, not in a
runtime that talks to it.

**Hook source layering** (per kind, alphabetical within each layer):

```
assets/runtime-base/hooks/<event>.d/                          # every runtime
assets/runtimes/<rt>/hooks/<event>.d/                         # runtime-wide
assets/runtimes/<rt>/project_types/<type>/hooks/<event>.d/    # type-specific
assets/databases/<dbtype>/hooks/<event>.d/                    # DB containers
assets/services/<svc>/hooks/<event>.d/                        # service containers
```

Numeric prefixes (`10-`, `90-`) for ordering within a directory.

## Mount story (cost map)

- **Runtime containers** already have `/mnt/assets/runtimes/...`
  bind-mounted (per AGENTS.md "Authoring verbs and tools"), so runtime
  hooks are reachable for free. Swift `podman exec`s the container
  and runs `run-parts /mnt/assets/.../hooks/<event>.d/`. **Lowest
  implementation cost — start here.**
- **Database containers** are stock postgres/mysql/mariadb images
  today, no mpd assets mounted. Either add a bind mount or pipe hook
  scripts via stdin. Plumbing required.
- **Service containers** — same story as DB containers. Plumbing
  required.

Phasing implication: wire the hook engine for runtime containers
first, migrate the hottest hardcoded Swift logic into it as the proof,
then extend to DB and service containers.

## Open design questions (deferred until planning)

- **Failure semantics per event.** `start` / `configure` hooks should
  abort the verb on failure (loudly). `stop` / `delete` hooks should
  log-but-continue (you can't "fail to stop" — that just leaves debris).
- **`pre-` / `post-` distinction** so e.g. db-init runs *after* the
  container is up.
- **Env-var contract.** Each hook gets a documented set of `MPD_*`
  variables (project name, type, runtime, db, paths, current verb,
  current event). Stable contract is what makes hooks safe to write
  without reading mpd's internals.
- **Cross-layer ordering.** Strictly by layer (base → runtime →
  type → db → service), then alphabetical within each, vs interleaved.
  Strictly by layer is more explicit; that's the current bet.
- **Concrete event list.** What events exist for each container kind,
  with what context. Comes out of mapping today's hardcoded Swift
  branches.

## Where this is going to live

When implemented:

- Swift: `mpd/Runtime/Hooks.swift` (or similar) — the dispatcher,
  bind-mount-aware exec, env-var construction, failure-propagation
  rules.
- Assets: `assets/<kind>/<…>/hooks/<event>.d/*.sh` — the actual hook
  scripts.
- Docs: this file expands into the user-facing reference for hook
  authors (event catalog, env-var table, examples).
