# `assets/runtime-base/` — runtime base layer

Code that turns a fresh Debian Trixie container into a "runtime base":
the foundation any specific runtime (`assets/runtimes/<rt>/`) builds on
top of.

- **`bootstrap.sh`** — phase-1 root-context script. The single allowed
  root entry point (see [AGENTS.md §"Mandatory privilege rule"](../../AGENTS.md)).
  Creates the dev user, sets up sshd + sudoers + `/etc/mpd` identity +
  `/srv/{projects,data,dbs,tools,personal}` layout. Symlinks `tools/*`
  into `/srv/tools/_base/` and adds that dir to PATH for every login
  shell.
- **`Containerfile`** — base image definition (`mpd-debian-trixie-systemd`).
- **`tools/`** — executable tools available **in any runtime** after
  bootstrap. On PATH as `/srv/tools/_base/<name>`. Currently:
  `claude-install`, `node-install`, `set-mpd-env`. Adding a new one =
  drop a file here and recreate runtimes.
- **`lib/`** — sourced libraries used by tools and project-type scripts:
  `source-mpd-env.sh` (loads the layered MPD_* env), `nvm-env.sh`
  (sources nvm in non-login contexts). Not on PATH.

After this layer, `assets/runtimes/<rt>/build.sh` runs as the dev user
and adds runtime-specific tooling on top.

See [AGENTS.md](../../AGENTS.md) for the privilege rule and tool
authoring contract; [docs/ARCHITECTURE.md §7](../../docs/ARCHITECTURE.md)
for the verb/tool model.
