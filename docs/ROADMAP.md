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

- **In-place runtime upgrades** — runtime containers are treated as
  pets, not cattle: a developer's `php` runtime accumulates installed
  tools, shell history, SSH known_hosts, and half-finished work, so
  "delete and recreate" is the wrong answer to a changed asset. The
  four infra services use a `mpd.service.revision` label plus
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
  `cloudflared`) as the network transport for remote hosts.
  Proxmox is a headless remote hypervisor, so the `mpd-virt`
  orchestrator role drives it over its REST API / `qm`/`pvesh`, and
  the host-side CA-trust + `*.mpd.test` resolver bits land on the
  user's separate workstation. Since the user already runs one CF
  Zero Trust client to reach Proxmox, mpd reuses it: a `cloudflared`
  connector inside the VM advertises the container CIDR
  (`10.163.<NNN>.0/24`, dnsmasq `10.163.<NNN>.3`) as a private route; CA
  trust is unchanged. Keeps mpd's client-side contract
  transport-agnostic — three facts — (1) a route to
  `10.163.<NNN>.0/24` exists, (2) the VM's zone resolves to those IPs,
  (3) the mpd CA is trusted — and mpd should *document/emit* these
  rather than program the user's VPN client. In practice a scoped
  `sudo ip route add 10.163.<NNN>.0/24 …` beats fighting WARP
  split-tunnel when a work VPN is up at the same time — both want
  to own routes, and a single-/24 static route coexists cleanly.
  Caveats: the route needs a next-hop/iface that actually carries
  the /24 to the VM (the ZT client still has to be up), and it must
  be made persistent across reboots (NM dispatcher /
  systemd-networkd / login hook). Distinct from the cftunnel ZT
  item above (that exposes *projects*; this is the *host↔VM*
  transport). No work scheduled.

- **Feel familiar to OS-native container CLIs (NOT a substrate change)**
  — the three OS vendors now ship native Docker-CLI-shaped
  Linux-container tooling: **Apple `container`** (Swift, per-container
  lightweight VMs via the Containerization framework, macOS 26) and
  **Microsoft `wslc`** (native runtime built into WSL, `container.exe`
  alias, GA ~fall 2026), alongside podman on Linux. All converge on the
  `run/build/ls/exec/logs/start/stop/rm` grammar — `container` is
  becoming the universal command name, and even non-devs will learn it.
  **Firm design boundary: mpd/mpd-virt will NEVER adopt Apple
  `container` or `wslc` as its runtime — it keeps podman + the
  persistent Debian VM permanently.** (mpd's model depends on a
  persistent systemd/SSH host, podman **pods** with shared IPC/shm
  (behat/Chromium `--shm-size`), and one shared network + local DNS
  (`10.163.<NNN>.0/24`, the VM's zone) — none of which fit
  one-micro-VM-per-container anyway.) The convergence matters for
  **ergonomics only**: mpd's `create/start/stop/delete/show` already
  map onto that grammar, so mpd feels familiar to anyone fluent in
  `docker`/`container`/`wslc` — while staying a *higher* project-level
  abstraction, not a docker clone. Action when picked up: audit the CLI
  for gratuitous divergence from the shared verb vocabulary; do NOT
  touch the runtime. No work scheduled. (Apple `container`/`wslc` DO
  get used — but only by the standalone `mdl-demo` image below, a
  separate product from mpd.)

- **`mdl-demo` — standalone all-in-one Moodle demo image** — a
  single published OCI image (Apache+PHP+MariaDB+Moodle+demo data)
  runnable by *anyone* with `container run` / `wslc run` / `docker run`,
  **without mpd installed**. Distinct from the in-VM `demo` verb (which
  provisions a Moodle project inside the mpd VM); this is a
  distributable, self-contained on-ramp for non-devs — an instant,
  disposable Moodle you can throw away. Design calls:
  - **Inherits the universal CLI grammar** — no bespoke CLI; the demo
    *is* a container, so `container run` is the install. The growing
    docker-literate (incl. non-dev) audience is a feature here.
  - **All-in-one single container** fits Apple `container`'s
    one-VM-per-container model cleanly — none of mpd's pod / shared-shm
    / shared-network / `*.mpd.test` substrate friction applies.
  - **Publish, don't build** — versioned image on a registry; `run`
    pulls (seconds, not minutes).
  - **`wwwroot` set at runtime** (env var or first-request
    autodetect), never a baked hostname — else non-default `-p` ports
    break Moodle redirects/logins. First-run step lives in the Go UI.
  - **Try plugins in the sandbox** — install any free or paid plugin
    into the throwaway Moodle to evaluate it before using it for real;
    the plugin list comes from a companion index repo (`mdl-plugins`)
    and prebuilt site setups from `mdl-recipes`. Trying untrusted code
    in a disposable container is also a safety win (zero blast radius).
  - **Two API surfaces, kept separate**: (1) *lifecycle* (up/down) via
    platform-native thin layers — Apple Containerization (Swift),
    `wslc` API, or the `container`/`docker` CLI; (2) *management* (admin
    pass, sample course, plugin install, reset) via an **in-container Go
    HTTP/JSON API**, identical on every platform. Build management once
    (Go, in the image); web UI + native apps are thin clients. Native
    apps own lifecycle only, then embed the web UI — don't reimplement
    management per platform.
  - Phase 1: CLI + internal Go web UI. Phase 2: native macOS/Windows
    apps wrapping it via the Swift/MS container APIs.
  - Naming: `mdl-demo`/`moodle-demo` reads more honestly than
    `mpd-demo` since it runs without mpd; mpd may optionally
    build/publish it. No work scheduled.

- **`mdl-plugins` / `mdl-recipes` — companion index repos** —
  `mdl-plugins` holds a list of plugins (name, versions, Moodle-version
  compat, source/download, checksums); `mdl-recipes` holds
  site-installation recipes (predefined setups: a Moodle version + a
  plugin set + config). Both are plain git repos of static manifests
  that the demo, mpd, and composer read to install plugins or stand up
  a recipe. Static + mirrorable + signable = trivial to host and easy
  to fork. No work scheduled.
