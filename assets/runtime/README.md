# The unified runtime

The one runtime container mpd creates (during `mpd --vm-setup`):
PHP 8.1–8.5 with FPM, Composer, Node.js (nvm), DB clients (postgres,
mariadb, mysql), and caddy (apt) as the in-runtime TLS frontdoor.

It is treated like a VM: created once from a pre-baked image, then
upgraded in place. mpd never rebuilds it on its own;
`mpd --runtime-rebuild` is for a runtime someone has broken.

- **`Containerfile`** — the published image (`runtime.Image` in
  `go/internal/runtime/runtime.go`, `ghcr.io/mutms/mpd-runtime:<tag>`):
  Debian plus what `bootstrap/60-install-software.sh` installs, so a
  fresh runtime is a pull plus configuration. `github-publish.sh` builds
  it for arm64 + amd64 on a Mac and pushes it; bump the tag in both
  files (search/replace), commit, run the script. Build locally under the
  same pinned name to test a change.
- **`bootstrap/`** — the runtime's own steps, numbered apart from the
  VM's `bootstrap/10..30`:
  - `50-user.sh` — root, runtime create only. The single allowed
    root entry point (see [AGENTS.md §"Mandatory privilege rule"](../../AGENTS.md)):
    dev user with the VM's uid, sudoers, sshd keys-only, `/etc/mpd`
    identity, `/srv/{projects,data,dbs,extra}`, `$HOME` from `skel/` and
    `/var/lib/mpd/skel/`.
  - `60-install-software.sh` — apt, as the dev user: dist-upgrade, Sury +
    PGDG repos, every PHP version in `lib/php-configure.sh`, DB clients,
    caddy, tools. The one package list; the Containerfile runs the same
    script as root to pre-bake the image.
  - `70-configure-runtime.sh` — configuration, as the dev user: php.ini
    + FPM per version, `/usr/bin/php` → the project-aware dispatcher
    (Debian alternative, priority 1000), Composer, Node, the
    `mpd-caddy.service` unit (caddy as the dev user), `/srv/data` perms.
  
  Create runs 50 → 60 → 70. `mpd --vm-setup` runs 70 on an existing
  runtime; `mpd --vm-upgrade` (or `mpd --runtime-upgrade`) runs 60 → 70.
  All idempotent.
- **`skel/`** — files copied into the dev user's `$HOME` at runtime
  create (`/etc/skel/`-style). Ships a `.bashrc` with PATH, prompt and
  nvm defaults and a `.ssh/known_hosts` pre-populated for common forges.
  User overrides go in `/var/lib/mpd/skel/` on the VM host.
- **`bin/`** — executables on the dev user's PATH as
  `/opt/mpd/assets/runtime/bin/<name>`, read straight out of the assets
  tree; nothing is copied or symlinked. `claude-install`, `node-install`,
  `composer-install`, `composer-upgrade`, and the `php`
  wrapper. Adding one = drop a file here; it is live at once.
- **`lib/`** — sourced libraries used by tools and project-type scripts:
  `php-configure.sh` (the PHP version list, package list and per-version
  setup shared by 60, 70 and `php-install`), `source-mpd-env.sh` (loads
  the layered MPD_* env), `nvm-env.sh` (sources nvm in non-login script
  contexts where `~/.bashrc` isn't auto-sourced), `project-template.sh`
  (seeds a project from its type's `template/` and maintains
  `.git/info/exclude`). Not on PATH.
- **`caddy/`** — the frontdoor: `mpd-caddy.sh` (service entry: render,
  watch `/srv/meta`, validate + reload), `gen-caddyfile.sh` (renders
  vhosts from `/srv/meta/*/urls.json`), `templates/header.caddyfile`.
- **`project_types/moodle/`** — Moodle support: `phpunit`, `behat`,
  `mdl-cron`, `mdl-cache-purge`, `mdl-install`, `mdl-upgrade`, `grunt`,
  `mpci` / `mpci-install`, `mdl-data-backup` / `mdl-data-restore`. See
  `docs/usage.md` for the full per-tool table.
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
  project alongside the `template/` files. See `docs/architecture.md` §6.

PHP version is resolved per project from the layered MPD_PHP_VERSION
(runtime default → type default → user → project) — see the `php`
wrapper and `source-mpd-env.sh`. Outside `/srv/projects/<n>/` it falls
back to a pinned version (8.2), so `php -v` from `$HOME`
always answers the same thing — which is what IDE interpreter probes
need. Point PhpStorm at `/usr/bin/php` for the dispatcher, or at
`/usr/bin/php8.3` (etc.) to pin one version.

See [AGENTS.md](../../AGENTS.md) for the privilege rule and tool
authoring contract; [docs/architecture.md §7](../../docs/architecture.md)
for the verb/tool model.
