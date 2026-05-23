# `assets/runtime-base/` — runtime base layer

Code that turns a fresh Debian Trixie container into a "runtime base":
the foundation any specific runtime (`assets/runtimes/<rt>/`) builds on
top of.

- **`bootstrap.sh`** — phase-1 root-context script. The single allowed
  root entry point (see [AGENTS.md §"Mandatory privilege rule"](../../AGENTS.md)).
  Creates the dev user, sets up sshd + sudoers + `/etc/mpd` identity +
  `/srv/{projects,data,dbs,tools}` layout. Seeds `/home/<user>/` from
  `skel/` (shipped defaults) and from `/var/lib/mpd/skel/` (VM-host
  overrides — empty by default). Symlinks `tools/*` into
  `/srv/tools/_base/`. PATH for `/srv/tools/*` is set by the dev user's
  `~/.bashrc` shipped via skel.
- **`Containerfile`** — base image definition (`mpd-debian-trixie-systemd`).
- **`skel/`** — files copied into the dev user's `$HOME` at runtime
  create (`/etc/skel/`-style). Ships a `.bashrc` with PATH + nvm + cd
  defaults and a `.ssh/known_hosts` pre-populated for common forges.
  User overrides go in `/var/lib/mpd/skel/` on the VM host.
- **`tools/`** — executable tools available **in any runtime** after
  bootstrap. On PATH as `/srv/tools/_base/<name>` via the skel bashrc.
  Currently: `claude-install`, `node-install`, `set-mpd-env`. Adding a
  new one = drop a file here and recreate runtimes.
- **`lib/`** — sourced libraries used by tools and project-type scripts:
  `source-mpd-env.sh` (loads the layered MPD_* env), `nvm-env.sh`
  (sources nvm in non-login script contexts where ~/.bashrc isn't
  auto-sourced). Not on PATH.

After this layer, `assets/runtimes/<rt>/build.sh` runs as the dev user
and adds runtime-specific tooling on top.

See [AGENTS.md](../../AGENTS.md) for the privilege rule and tool
authoring contract; [docs/ARCHITECTURE.md §7](../../docs/ARCHITECTURE.md)
for the verb/tool model.
