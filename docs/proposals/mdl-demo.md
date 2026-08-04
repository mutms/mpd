# `mdl-demo` — throwaway Moodle demos

Parked design brainstorm (moved out of [`ROADMAP.md`](../ROADMAP.md)).
No work scheduled; delete this file when (a shape of) it ships.

A "fat" all-in-one image (Apache+PHP+MariaDB+Moodle+demo data):
instant, disposable Moodle, distinct from the in-VM `demo` verb (which
provisions a Moodle project inside the mpd VM). It ships **two ways for
two audiences**, sharing the image, the `mdl-plugins` index, and the
`mdl-recipes` setups:

## (A) Local demo *builder* — a host app (the primary delivery)

A macOS Go binary — a cousin of mpd-virt (host binary + per-demo
registry, wrapping the container CLI) — that provisions fat containers
and drives them, with the **control panel served on the host at a fixed
`http://127.0.0.1:8099`**. The user picks a Moodle version + plugin set
(a GUI over `mdl-recipes`/`mdl-plugins`); each demo is reached at
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

## (B) Standalone image — distributable (secondary)

The same fat image run *directly* by anyone with `container
run`/`wslc run`/`docker run`, **without the builder or mpd** — a
self-contained on-ramp for the docker-literate. Here management (admin
pass, sample course, plugin install, reset) lives *in* the container as
a Go HTTP/JSON API (there is no host tool to lean on), lifecycle is the
native CLI, and it inherits the universal container grammar. All-in-one
single container fits Apple `container`'s one-VM-per-container model
(none of mpd's pod / shared-shm / `*.mpd.test` friction);
publish-don't-build (versioned image on a registry, `run` pulls in
seconds).

## Shared calls

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
