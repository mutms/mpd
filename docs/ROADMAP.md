# Roadmap

What might land in mpd. Order is rough; nothing here is a hard commit.
Items move from **Parked** to **Queued** when a real use case justifies
the work.

## Queued

Concrete shape, a use case driving it.

- **`mdl-backup` / `mdl-restore` (Moodle)** — one tar bundle per
  project (dataroot + DB dump + config snapshot), pulled via the
  fileaccess SSH endpoint. Moodle-only because the dataroot ↔ DB
  coupling makes "snapshot the project" a real, named unit; other
  project types keep state in `git`.

## Parked: other ideas

Real possibilities, not committed work.

- **Alternate repo/branch for VM provisioning** — an env var (e.g.
  `MPD_REPO`, `MPD_BRANCH`) that `create-vm.ps1` / `create-vm.sh`
  pass to cloud-init so the VM clones a feature branch or a fork
  instead of the default `main`. Useful during development of mpd
  itself: test a branch end-to-end without changing the scripts
  permanently. Needs a matching override in `configure-client.ps1`
  so the self-update and branch-awareness story is consistent.

- **Self-update** — after the first stable release, long-lived VMs
  will need a way to upgrade mpd without re-provisioning. Shape TBD
  (standalone tool, `mpd --self-update`, or something else).

- **Runtime SSH banner** — install a branded `/etc/motd` inside each
  runtime container (php, node, util) so users see a welcome message
  and tool hints when they SSH into `<rt>.runtime.mpd.test`. Common
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
