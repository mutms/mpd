# Roadmap

What might land in mpd. Order is rough; nothing here is a hard commit.
Items move from **Parked** to **Queued** when a real use case justifies
the work.

## Queued

Concrete shape, a use case driving it.

- **`publish` / `unpublish` tools** — public preview URLs via
  Cloudflare Tunnel + Cloudflare Access. Per-project opt-in;
  `cloudflared` sidecar attaches to the runtime pod; auth happens at
  Cloudflare's edge. For sharing a project with a teammate, client,
  or vibe-coding friend on an iPad.
- **`mdl-backup` / `mdl-restore` (Moodle)** — one tar bundle per
  project (dataroot + DB dump + config snapshot), pulled via the
  fileaccess SSH endpoint. Moodle-only because the dataroot ↔ DB
  coupling makes "snapshot the project" a real, named unit; other
  project types keep state in `git`.

## Parked: beginner-facing front door

A separate distribution path is parked for later: a `mutms/mpd-machine`
repository carrying the platform-specific release packages (Windows
Hyper-V `setup.cmd`, macOS UTM `setup.command`, generic-VM artifacts),
and a landing page at `mpd-machine.org` aimed at developers who are new
to Moodle but comfortable running an installer. The promise on that side
is narrower than mpd's own: download, run the installer, type
`demo moodle v5.2.0`, get a working site.

What makes this viable as a beginner story rather than just another
local-Moodle recipe is that Claude Code (or another agent) can be
installed inside the runtime and asked to debug whatever breaks. The
sandbox-VM design that exists for security reasons doubles as
agent-safety — if the agent makes a mess, `mpd-machine rebuild` and
start again — so first-line support effectively runs on the user's
laptop. The mpd repository itself stays targeted at intermediate
developers regardless of how the beginner front door evolves.

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
  runtime container (php, node, trixie) so users see a welcome message
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
  php, node, and trixie runtimes to a registry (GitHub Container
  Registry or similar) so `mpd --runtime-create` pulls instead of
  builds. Cuts the first-run wait from several minutes to seconds.
  `demo` becomes near-instant after the image pull. `make images`
  builds and pushes all runtime images; CI runs it on release tags.
  Local `--runtime-build` flag kept for dev iteration.

- **`mpd --gc`** — sweep unreferenced DB containers, orphaned data
  dirs, dnsmasq records for deleted projects. Open question: destructive
  default or interactive plan + `--yes`?

- **Graceful shutdown / postgres recovery** — when the mpd-machine VM
  is power-cycled (UTM force-stop, host sleep that doesn't resume
  cleanly, hard reboot), postgres containers come up doing crash
  recovery on the next start. Moodle's first request after resume can
  hit `Database connection failed` while recovery is still in flight,
  even though the container is "running". Possible shapes: a
  user-systemd unit inside the VM that stops mpd containers cleanly on
  `poweroff.target` / `suspend.target`; a `pg_isready` wait inside
  `mpd --start` for every per-project DB before declaring success;
  or a small connection-retry shim in the runtime PHP wrappers. Pick
  whichever costs the least to implement and has the smallest blast
  radius.
- **Newbie-onboarding docs** — for Moodle-curious folks who don't
  already know what a plugin is. Pairs naturally with `publish` once
  it ships.
- **AI-driven demo provisioning** — agent running inside mpd-machine's
  Gnome desktop drives Firefox through Moodle's first-time install
  wizard, installs a set of plugins, populates the site with sample
  course content and activity data, hands you a fully-populated demo
  site. Useful for workshop prep, training environments, "what does
  this plugin actually look like" pitches. The data-generator side
  has prior work to build on; the new piece is the agent-driven
  first-install / plugin-install flow.
