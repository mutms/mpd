# `assets/runtime-base/` — runtime base layer

Code that turns a fresh Debian Trixie container into a "runtime base":
the foundation the unified runtime (`assets/runtime/`) builds on
top of.

- **`bootstrap.sh`** — phase-1 root-context script. The single allowed
  root entry point (see [AGENTS.md §"Mandatory privilege rule"](../../AGENTS.md)).
  Creates the dev user, sets up sshd + sudoers + `/etc/mpd` identity +
  `/srv/{projects,data,dbs,extra}` layout. Seeds `/home/<user>/` from
  `skel/` (shipped defaults) and from `/var/lib/mpd/skel/` (VM-host
  overrides — empty by default). Tool directories are put on PATH by the
  dev user's `~/.bashrc` (shipped via skel), read straight out of the
  assets tree — nothing is copied or symlinked.
- **`Containerfile`** — base image definition (`mpd-debian-trixie-systemd`).
- **`skel/`** — files copied into the dev user's `$HOME` at runtime
  create (`/etc/skel/`-style). Ships a `.bashrc` with PATH + nvm
  defaults and a `.ssh/known_hosts` pre-populated for common forges.
  User overrides go in `/var/lib/mpd/skel/` on the VM host.
- **`tools/`** — executable tools available **in any runtime**. On PATH
  as `/opt/mpd/assets/runtime-base/tools/<name>` via the skel bashrc.
  Currently: `claude-install`, `node-install`, `set-mpd-env`. Adding a
  new one = drop a file here and rebuild the runtime.
- **`lib/`** — sourced libraries used by tools and project-type scripts:
  `source-mpd-env.sh` (loads the layered MPD_* env), `nvm-env.sh`
  (sources nvm in non-login script contexts where ~/.bashrc isn't
  auto-sourced). Not on PATH.

After this layer, `assets/runtime/build.sh` runs as the dev user
and adds the language stacks and the caddy frontdoor on top.

See [AGENTS.md](../../AGENTS.md) for the privilege rule and tool
authoring contract; [docs/ARCHITECTURE.md §7](../../docs/ARCHITECTURE.md)
for the verb/tool model.
