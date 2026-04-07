# `assets/runtimes/` — per-runtime customization

One subdirectory per runtime that builds on the runtime base
(`../runtime-base/`). Each runtime ships a `build.sh` (phase-2,
runs as the dev user) plus optional `tools/` and `project_types/`.

Current runtimes:

- **`php/`** — PHP 8.1–8.5 + FPM, Composer, Node (nvm). Project type:
  `moodle`. Runtime-specific tools: `composer-install`, `composer-upgrade`,
  the `php` version-aware wrapper.
- **`node/`** — Node.js (nvm) + DB clients. Project type: `astro`.
  No runtime-specific tools — everything node devs need is in
  `runtime-base/tools/` or in `project_types/astro/tools/`.
- **`trixie/`** — bare Trixie + the shared base. No language stack,
  no project types beyond `bare`. The developer SSHes in and installs
  whatever they need.

Each runtime directory typically contains:

- `build.sh` — phase-2 build, runs as dev user with sudo for individual
  privileged ops. Required.
- `configuration.json` — runtime IP, sidecar list, etc. Read by Swift.
- `mpd-defaults.env` — runtime-wide defaults for `MPD_*` env keys
  (see [docs/ARCHITECTURE.md §8](../../docs/ARCHITECTURE.md)).
- `tools/` — runtime-wide executables on PATH inside the runtime.
- `project_types/<type>/` — project-type-specific code (templates,
  configure scripts, type-only tools). PATH precedence: type tools
  win over runtime tools win over base tools.

See [AGENTS.md](../../AGENTS.md) for the privilege rule, tool authoring
contract, and naming conventions; [docs/ARCHITECTURE.md §7](../../docs/ARCHITECTURE.md)
for the full verb/tool model.
