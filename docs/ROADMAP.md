# Roadmap

What might land in mpd. Order is rough; nothing here is a hard commit.
Items move from **Parked** to **Queued** when a real use case justifies
the work.

## Queued

Concrete shape, a use case driving it.

- **`mdl-backup` / `mdl-restore` (Moodle)** — one tar bundle per
  project (dataroot + DB dump + config snapshot), copied off the VM
  from `/srv/backups/`. Moodle-only because the dataroot ↔ DB
  coupling makes "snapshot the project" a real, named unit; other
  project types keep state in `git`.

- **`mpd ps <project>`** — single-screen project status. Runtime +
  PHP version + DB engine/version + active sidecars + URLs + xdebug
  mode, all in one view. Pattern borrowed from Laravel's
  `php artisan about` (familiar to Moodle devs increasingly working
  in both ecosystems). All data already exists in
  `cli.ShowProject` / state files — this is presentation, not new
  logic.

- **`mpd env <project>`** — print the resolved layered env for a
  project (runtime defaults → type defaults → vm overrides → project
  mpd.env), showing which layer set each `MPD_*` key. Pattern
  borrowed from Laravel's `php artisan config:show`. Especially
  useful when the four-layer cascade lands a value you didn't
  expect. Implementation: invoke `source-mpd-env.sh` with verbose
  tracing, or re-implement the resolver in Go for cleaner output.

## Parked: other ideas

Real possibilities, not committed work.

- **In-place runtime upgrades** — runtime containers are treated as
  pets, not cattle: a developer's `php` runtime accumulates installed
  tools, shell history, SSH known_hosts, and half-finished work, so
  "delete and recreate" is the wrong answer to a changed asset. The
  three infra services use a `mpd.service.revision` label plus
  `podman.Client.RemoveIfOutdated` to force recreation; runtimes
  deliberately have no such mechanism and should not grow one.
  Instead they want upgrade scripts that run *inside* the existing
  container and converge it — the same shape as
  `bootstrap/99-update.sh` for the VM. Driven by ordinary asset and
  tooling drift over a runtime's life, not by re-addressing: changing
  an existing VM's ID is not a supported operation.

- **Runtime SSH banner** — install a branded `/etc/motd` inside each
  runtime container (php, node, util) so users see a welcome message
  and tool hints when they SSH into `<rt>.runtime.<NNN>.mpd.test`. Common
  content in `assets/runtime-base/motd` (installed by `bootstrap.sh`),
  runtime-specific additions in `assets/runtimes/<rt>/motd` (appended
  by `build.sh`). Written directly to `/etc/motd` — no PAM/update-motd.d
  needed in containers.

- **`mpd purge` vs `mpd delete` split** — `delete` removes containers,
  DB, and mpd state (today's behavior); `purge` additionally wipes the
  source checkout at `/srv/projects/<project>/`. Useful when a demo or
  experiment is fully thrown away and disk space matters.

- **Pre-built runtime images** — publish versioned OCI images for the
  php, node, and util runtimes to a registry (GitHub Container
  Registry or similar) so `mpd --runtime-create` pulls instead of
  builds. Cuts the first-run wait from several minutes to seconds.
  `demo` becomes near-instant after the image pull. `make images`
  builds and pushes all runtime images; CI runs it on release tags.
  Local `--runtime-build` flag kept for dev iteration.

- **`mpd --gc`** — sweep unreferenced DB containers, orphaned data
  dirs, dnsmasq records for deleted projects. Open question: destructive
  default or interactive plan + `--yes`?

- **Cloudflare Zero Trust integration for cftunnel** — the v1
  cftunnel flow exposes projects publicly (or behind whatever the
  user manually configures in the CF dashboard). A future iteration
  could codify the Zero-Trust-protected workflow: a sibling project-
  type (or a flag on `cftunnel`) that targets the per-app CF wizard,
  pre-fills the internal hostname / port, and produces a 1:1
  Access-protected app per target. Naming convention to consider:
  `<target>-cftunnel` (per-target, ZT-gated) vs bare `cftunnel`
  (shared connector, public-or-manually-protected). Also: a per-
  moodle `MPD_PHP_MOODLE_CFTUNNEL_HOST=<custom>` override so the
  wwwroot detection works when the public hostname diverges from
  `<projectname><domain>`. Parked until a real use case drives the
  shape.

- **Newbie-onboarding docs** — for Moodle-curious folks who don't
  already know what a plugin is.
- **AI-driven demo provisioning** — agent running inside mpd VM's
  Gnome desktop drives Firefox through Moodle's first-time install
  wizard, installs a set of plugins, populates the site with sample
  course content and activity data, hands you a fully-populated demo
  site. Useful for workshop prep, training environments, "what does
  this plugin actually look like" pitches. The data-generator side
  has prior work to build on; the new piece is the agent-driven
  first-install / plugin-install flow.

- **`mdl-demo` — throwaway Moodle demos.** A "fat" all-in-one image
  (Apache+PHP+MariaDB+Moodle+demo data): instant, disposable Moodle,
  distinct from the in-VM `demo` verb (which provisions a Moodle project
  inside the mpd VM). Design brainstorm in
  [`proposals/mdl-demo.md`](proposals/mdl-demo.md). No work scheduled.
