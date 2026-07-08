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

- **`mpd ps <project>`** — single-screen project status. Runtime +
  PHP version + DB engine/version + active sidecars + URLs + xdebug
  mode, all in one view. Pattern borrowed from Laravel's
  `php artisan about` (familiar to Moodle devs increasingly working
  in both ecosystems). All data already exists in
  `Mpd.Project.show` / state files — this is presentation, not new
  logic.

- **`mpd env <project>`** — print the resolved layered env for a
  project (runtime defaults → type defaults → vm overrides → project
  mpd.env), showing which layer set each `MPD_*` key. Pattern
  borrowed from Laravel's `php artisan config:show`. Especially
  useful when the four-layer cascade lands a value you didn't
  expect. Implementation: invoke `source-mpd-env.sh` with verbose
  tracing, or re-implement the resolver in Swift for cleaner output.

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

- **Composer-based Moodle installation + plugin management** —
  Moodle is moving toward `composer create-project moodle/moodle`
  as the production install path, with plugins managed via
  composer.json too (no more zip-and-drop). This is the future
  shape of Moodle deployments, but not yet fully stable, and gated
  on the new Moodle marketplace landing (which may or may not go
  smoothly). When it does stabilize, mpd's moodle project type gets
  a `composer` install mode alongside the current `git-clone`
  mode, and the layered env grows a way to declare plugins
  declaratively. Wait-and-see; no work scheduled until upstream
  settles.

- **`mpd quickstart` driven by composer-based Moodle install** —
  once composer-based Moodle install is stable (item above), the
  one-shot quickstart flow gets rebuilt on top of it instead of the
  current `git clone moodle/moodle` path. The win is plugin
  management: `composer require moodle-local/<plugin>` becomes a
  first-class part of project setup, so `mpd quickstart moodle52
  --plugins=local_foo,mod_bar` provisions a Moodle install with
  those plugins already wired in. The current `demo moodle v5.2.0`
  one-liner stays as the simple-case shortcut. Blocked on the
  composer install item above.

- **Proxmox host + single Cloudflare client** — support Proxmox VE as
  an "mpd VM" host platform, with Cloudflare Zero Trust (WARP +
  `cloudflared`) as the network transport instead of WireGuard.
  Proxmox is a headless remote hypervisor, so the `mpd-virt`
  orchestrator role drives it over its REST API / `qm`/`pvesh`, and
  the host-side CA-trust + `*.mpd.test` resolver bits land on the
  user's separate workstation. Since the user already runs one CF
  Zero Trust client to reach Proxmox, mpd reuses it: a `cloudflared`
  connector inside the VM advertises the container CIDR
  (`10.163.0.0/16`, dnsmasq `10.163.0.3`) as a private route; WARP
  split-DNS handles `*.mpd.test`; CA trust is unchanged. Reframes
  WireGuard as one transport impl rather than a fixed dependency.
  Gotchas: CIDR overlap with other WARP routes, and split-DNS
  precedence for `.test` vs Cloudflare Gateway. Distinct from the
  cftunnel ZT item above (that exposes *projects*; this is the
  *host↔VM* transport). No work scheduled.
