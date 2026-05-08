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

- **Ubuntu + KVM as a third polished `mpd-machine` platform** —
  feature-parity with `macos-utm/` and `windows-hyperv/`: a
  `setup.sh` that drives QEMU with KVM acceleration (likely via
  libvirt's default network), prepares the mpd CA on the host, and
  configures host networking (`ip route`, systemd-resolved drop-in
  for `*.mpd.test`, `update-ca-certificates`) inside the same
  upfront fenced sudo block; pre-warm + lifecycle scripts mirror
  the other two. Detailed brief for the implementer in
  [`mpd-machine/platforms/ubuntu-kvm/README.md`](../mpd-machine/platforms/ubuntu-kvm/README.md).
  Ubuntu desktop users use [`generic-vm/`](../mpd-machine/platforms/generic-vm/README.md)
  in the meantime.

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
