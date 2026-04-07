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
- **Automated Windows + Hyper-V bootstrap** —
  `mpd-machine/platforms/windows-hyperv/setup.ps1` parallel to
  `macos-utm/create-vm.sh`: drive `New-VM`, boot the Debian Trixie
  cloud image with cloud-init, install pubkey, run `provision-vm.sh`
  inside the VM. Until then, Windows users follow
  [`platforms/generic-vm/`](../mpd-machine/platforms/generic-vm/README.md);
  the manual flow already works on Hyper-V with the netinst ISO.
- **`mdl-backup` / `mdl-restore` (Moodle)** — one tar bundle per
  project (dataroot + DB dump + config snapshot), pulled via the
  fileaccess SSH endpoint. Moodle-only because the dataroot ↔ DB
  coupling makes "snapshot the project" a real, named unit; other
  project types keep state in `git`.

## Parked

Real possibilities, not committed work.

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
