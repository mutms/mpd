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

- **`mdl-demo` — throwaway Moodle demos.** A "fat" all-in-one image
  (Apache+PHP+MariaDB+Moodle+demo data): instant, disposable Moodle,
  distinct from the in-VM `demo` verb (which provisions a Moodle project
  inside the mpd VM). It ships **two ways for two audiences**, sharing the
  image, the `mdl-plugins` index, and the `mdl-recipes` setups:

  **(A) Local demo *builder* — a host app (the primary delivery).** A macOS
  Go binary — a cousin of mpd-virt (host binary + per-demo registry,
  wrapping the container CLI) — that provisions fat containers and drives
  them, with the **control panel served on the host at a fixed
  `http://127.0.0.1:8099`**. The user picks a Moodle version + plugin set (a
  GUI over `mdl-recipes`/`mdl-plugins`); each demo is reached at
  `http://localhost:<port>`, plain HTTP — no SSL, no overlay, no DNS, no CA.
  - **Control plane at a fixed address; the workload may move.** The dead
    end is co-locating the panel with the thing whose address churns: Apple
    `container` hands each box a *new* vmnet IP every start AND does **not**
    register the name in the macOS system resolver (`ping mpd-<NNN>` fails on
    the host — the embedded DNS is container-to-container only). An
    in-container panel inherits both the moving IP and the fragile
    in-container systemd/user-session stack; a host panel sheds both.
  - **Durable per-demo port = bookmarkable URL.** The registry assigns a
    high host port once and reuses it forever, so `localhost:8140` is a
    demo's permanent address across restarts; the churning internal IP hides
    behind the `-p` map (or the binary proxying to the live `container
    inspect` IP). The portal is the phone book — open `:8099`, click a demo
    — so nobody memorises ports. Reconcile registry (intent) vs `container
    ls`/`inspect` (truth).
  - **The binary owns the gnarly `container run`** (`--cap-add ALL`, systemd
    PID 1, `-p`, wwwroot) — users click, never type it.
  - **Non-root after the one-time `container` install.** Only installing
    Apple's `container` (pkg + first `container system start`, the vmnet
    helper) needs admin. The builder, portal (high port), lifecycle,
    port-maps, `open`, and persistence via a **LaunchAgent** (not a
    LaunchDaemon) are all user-space. Rules that keep it so: high ports only
    (>1024), LaunchAgent not Daemon.
  - **UX:** a `.app` (`LSUIElement` menu-bar/agent, no Dock) and/or a
    LaunchAgent; singleton-open on launch (bind `:8099`, else just `open`
    the URL and exit); browser via macOS `open`. Self-updating single binary
    (fetch a build from GitHub Releases over its own HTTP → no quarantine;
    atomic rename-over the old path; relaunch via `syscall.Exec`).

  **(B) Standalone image — distributable (secondary).** The same fat image
  run *directly* by anyone with `container run`/`wslc run`/`docker run`,
  **without the builder or mpd** — a self-contained on-ramp for the
  docker-literate. Here management (admin pass, sample course, plugin
  install, reset) lives *in* the container as a Go HTTP/JSON API (there is no
  host tool to lean on), lifecycle is the native CLI, and it inherits the
  universal container grammar. All-in-one single container fits Apple
  `container`'s one-VM-per-container model (none of mpd's pod / shared-shm /
  `*.mpd.test` friction); publish-don't-build (versioned image on a
  registry, `run` pulls in seconds).

  **Shared calls:**
  - **`wwwroot` = the access URL**, set at provision/run time (env or
    first-request autodetect), never a baked hostname — else non-default
    ports break Moodle redirects/logins.
  - **Try plugins in the sandbox** — install any free/paid plugin into the
    throwaway Moodle to evaluate it first (list from `mdl-plugins`, setups
    from `mdl-recipes`). Untrusted code in a disposable container is a safety
    win (zero blast radius).
  - **Lead with the host app for non-devs (Phase 1), not "`container run` by
    hand."** "Just run the image" assumes away the moving IP, the port to
    remember, and the gnarly run command — exactly what non-devs trip on. So
    the builder app is primary; the raw standalone image serves the
    docker-literate. Phase 2: extend to Windows via the `wslc` API.
  - **Signing:** for dev, `go build` is enough (ad-hoc-signed, runs on the
    builder's own Mac) — no signing, devs compile it themselves. For
    distribution to non-devs, sign + notarize under a dedicated **individual
    CZ Apple Developer ID** (a known community name in the "signed by…" field
    beats an unknown org); notarize+staple the first-download `.dmg`/`.app`,
    while HTTP-fetched self-updates dodge quarantine. Deferred until there is
    a non-dev to hand it to.
  - Naming: `mdl-demo`/`moodle-demo` reads more honestly than `mpd-demo`
    since it runs without mpd; mpd may optionally build/publish the image.
    No work scheduled.
