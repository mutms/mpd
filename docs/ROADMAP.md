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

## Parked

Real possibilities, not committed work.

- **Self-update** — after the first stable release, long-lived VMs
  will need a way to upgrade mpd without re-provisioning. Shape TBD
  (standalone tool, `mpd --self-update`, or something else).

- **macOS + UTM setup parity** — bring `macos-utm/` up to the level of
  `windows-hyperv/`: a `setup.sh` that lists UTM VMs (via `utmctl`),
  detects the current one from the route, and handles create / switch /
  re-verify in one flow; `start.sh`, `stop.sh`, `uninstall.sh` wrappers;
  a `configure-client.sh` that automates the macOS laptop side (route,
  `/etc/resolver/mpd.test`, CA cert via `security add-trusted-cert`).
  Rough edge: macOS has no persistent static route flag (`-p`), so a
  LaunchDaemon plist is needed to survive reboots.

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
