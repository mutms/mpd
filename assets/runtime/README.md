# The unified runtime

The one runtime container mpd creates (during `mpd --vm-setup`):
PHP 8.1–8.5 with FPM, Composer, Node.js (nvm), DB clients (postgres,
mariadb, mysql), and caddy (apt) as the in-runtime TLS frontdoor.

It is built in two phases from this one directory. There used to be a
separate `assets/runtime-base/` holding phase 1; with exactly one runtime
the split bought nothing but an extra PATH tier and an extra place to
look, so it was merged here. The *phases* remain — they are a privilege
boundary, not a layering one.

- **`Containerfile`** — base image definition
  (`mpd-debian-trixie-systemd`). No `COPY`; the image is stock Debian
  plus systemd, and everything mpd-specific arrives through the two
  phases below and the read-only `/opt/mpd` mount.
- **`bootstrap.sh`** — phase-1 root-context script. The single allowed
  root entry point (see [AGENTS.md §"Mandatory privilege rule"](../../AGENTS.md)).
  Creates the dev user, sets up sshd + sudoers + `/etc/mpd` identity +
  `/srv/{projects,data,dbs,extra}` layout. Seeds `/home/<user>/` from
  `skel/` (shipped defaults) and from `/var/lib/mpd/skel/` (VM-host
  overrides — empty by default).
- **`build.sh`** — phase-2, as the dev user: installs PHP via the Sury
  repo, configures FPM pools, installs Composer + Node, registers the
  `php` wrapper as the Debian `php` alternative (priority 1000, pinned)
  so `/usr/bin/php` is the project-aware version dispatcher, and installs
  `mpd-caddy.service` (caddy running as the dev user).
- **`skel/`** — files copied into the dev user's `$HOME` at runtime
  create (`/etc/skel/`-style). Ships a `.bashrc` with PATH, prompt and
  nvm defaults and a `.ssh/known_hosts` pre-populated for common forges.
  User overrides go in `/var/lib/mpd/skel/` on the VM host.
- **`tools/`** — executables on the dev user's PATH as
  `/opt/mpd/assets/runtime/tools/<name>`, read straight out of the assets
  tree; nothing is copied or symlinked. `claude-install`, `node-install`,
  `composer-install`, `composer-upgrade`, and the `php`
  wrapper. Adding one = drop a file here and rebuild the runtime.
- **`lib/`** — sourced libraries used by tools and project-type scripts:
  `source-mpd-env.sh` (loads the layered MPD_* env), `nvm-env.sh`
  (sources nvm in non-login script contexts where `~/.bashrc` isn't
  auto-sourced), `project-template.sh` (seeds a project from its type's
  `template/` and maintains `.git/info/exclude`). Not on PATH.
- **`caddy/`** — the frontdoor: `mpd-caddy.sh` (service entry: render,
  watch `/srv/meta`, validate + reload), `gen-caddyfile.sh` (renders
  vhosts from `/srv/meta/*/urls.json`), `templates/header.caddyfile`.
- **`project_types/moodle/`** — Moodle support: `phpunit`, `behat`,
  `mdl-cron`, `mdl-cache-purge`, `mdl-install`, `mdl-upgrade`, `grunt`,
  `mpci` / `mpci-install`. See `docs/USAGE.md`
  for the full per-tool table.
- **`project_types/astro/`** — Astro dev-server support:
  `astro-rebuild`, `astro-upgrade`.
- **`project_types/<type>/template/`** — files seeded into the project
  directory itself (create-if-missing) and git-excluded there: `mpd.env`
  for every type, plus Moodle's `config.php` and
  `.phpstorm.meta.php/dml.php`. Adding a default project file = drop it
  here at the right relative path; no script change.
- **`project_types/<type>/generated/`** — the files the type's
  `scripts/configure.sh` renders itself (Moodle's `config-mpd.php`, whose
  `%%…%%` placeholders it substitutes). Not copied, but git-excluded in the
  project alongside the `template/` files. See `docs/ARCHITECTURE.md` §6.

PHP version is resolved per project from the layered MPD_PHP_VERSION
(runtime default → type default → user → project) — see the `php`
wrapper and `source-mpd-env.sh`. Outside `/srv/projects/<n>/` it falls
back to a pinned version (8.2), so `php -v` from `$HOME`
always answers the same thing — which is what IDE interpreter probes
need. Point PhpStorm at `/usr/bin/php` for the dispatcher, or at
`/usr/bin/php8.3` (etc.) to pin one version.

See [AGENTS.md](../../AGENTS.md) for the privilege rule and tool
authoring contract; [docs/ARCHITECTURE.md §7](../../docs/ARCHITECTURE.md)
for the verb/tool model.
