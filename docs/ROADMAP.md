# Roadmap

What might land in mpd. Order is rough; nothing here is a hard commit.
Items move from **Parked** to **Queued** when a real use case justifies
the work.

## Queued

Concrete shape, a use case driving it.

- **`mpd env <project>`** — print the layered `MPD_*` env for a project
  and say **which layer set each key**: runtime defaults → type
  defaults → your `mpd-virt.env` → the project's `mpd.env`. Pattern
  borrowed from Laravel's `php artisan config:show`.

  Not covered by `mpd status --json`, which is worth stating because it
  looks like it should be. That document's `settings` block is
  `effective.json` — the seven values a project type's `configure.sh`
  resolved (`phpVersion`, `dbTag`, `behat`, …), not the `MPD_*` set,
  and it records answers without reasons. The question `env` exists to
  answer is "why is this 1 when I never set it", and nothing can answer
  that from an answer alone.

  The case got stronger once `mpd-virt.env` started arriving from the
  Mac: a value you did not expect may have been set on a machine you
  are not logged into.

  Implementation: verbose tracing in `source-mpd-env.sh`, which is the
  only thing that implements the cascade — Go deliberately does not
  (see `ARCHITECTURE.md` §8), so re-implementing the resolver there
  would create the second copy that section exists to prevent.

## Parked: other ideas

Real possibilities, not committed work.

- **In-place runtime upgrades** — the runtime is cattle with a
  carry-on bag now: `mpd --runtime-rebuild` recreates it from current
  assets, and `mpd --runtime-backup` / `--runtime-restore` carry the
  personal pieces (Claude config, shell history — never binaries;
  tools are reinstalled fresh) across the rebuild via
  `assets/runtime/backup.d/` + `restore.d/` scripts.
  What remains parked is a *converging* upgrade that runs inside the
  existing container without a rebuild — the same shape as
  `bootstrap/99-update.sh` for the VM — for asset drift too small to
  justify a rebuild.

- **Runtime SSH banner** — install a branded `/etc/motd` inside the
  runtime container so users see a welcome message and tool hints when
  they SSH into `runtime.<NNN>.mpd.test`. Content in
  `assets/runtime/motd` (installed by `bootstrap.sh`, appended to by
  `build.sh`). Written
  directly to `/etc/motd` — no PAM/update-motd.d needed in containers.

- **`mpd purge` vs `mpd delete` split** — `delete` removes containers,
  DB, and mpd state (today's behavior); `purge` additionally wipes the
  source checkout at `/srv/projects/<project>/`. Useful when a demo or
  experiment is fully thrown away and disk space matters.

- **Pre-built runtime image** — publish a versioned OCI image for the
  unified runtime to a registry (GitHub Container Registry or similar)
  so `mpd --vm-setup` / `--runtime-rebuild` pulls instead of builds.
  Cuts the first-run wait from several minutes to seconds. `demo`
  becomes near-instant after the image pull. `make images` builds and
  pushes it; CI runs it on release tags.

- **`mpd --gc`** — sweep unreferenced DB containers, orphaned data
  dirs, dnsmasq records for deleted projects. Open question: destructive
  default or interactive plan + `--yes`?

- **Cloudflare Tunnel as a service** — the cftunnel project type was
  removed with the unified runtime; it returns as an extra service
  container (`mpd --service-enable=cftunnel`) able to expose any
  project to the internet, ideally with the Zero-Trust-protected
  workflow codified (per-app CF wizard, pre-filled internal
  hostname/port, 1:1 Access-protected app per target). Parked until a
  real use case drives the shape.

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
