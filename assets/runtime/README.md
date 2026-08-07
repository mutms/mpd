# The unified runtime

The one runtime container mpd creates (during `mpd --vm-setup`):
PHP 8.1–8.5 with FPM, Composer, Node.js (nvm), DB clients (postgres,
mariadb, mysql), and caddy (apt) as the in-runtime TLS frontdoor.

- **`build.sh`** — phase-2 build: installs PHP via the Sury repo,
  configures FPM pools, installs Composer + Node, registers the `php`
  wrapper as the Debian `php` alternative (priority 1000, pinned) so
  `/usr/bin/php` is the project-aware version dispatcher, and installs
  `mpd-caddy.service` (caddy running as the dev user).
- **`caddy/`** — the frontdoor: `mpd-caddy.sh` (service entry: render,
  watch `/srv/meta`, validate + reload), `gen-caddyfile.sh` (renders
  vhosts from `/srv/meta/*/urls.json`), `templates/header.caddyfile`.
- **`tools/`** — `composer-install`, `composer-upgrade`, the `php`
  wrapper.
- **`project_types/moodle/`** — Moodle support: `phpunit`, `behat`,
  `mdl-cron`, `mdl-cache-purge`, `mdl-install`, `mdl-upgrade`, `grunt`,
  `mpci` / `mpci-install`, `mdl-data-purge`. See `docs/USAGE.md`
  for the full per-tool table.
- **`project_types/astro/`** — Astro dev-server support:
  `astro-rebuild`, `astro-upgrade`.

PHP version is resolved per project from the layered MPD_PHP_VERSION
(runtime default → type default → user → project) — see the `php`
wrapper and `source-mpd-env.sh`. Outside `/srv/projects/<n>/` it falls
back to a pinned version (8.2), so `php -v` from `$HOME`
always answers the same thing — which is what IDE interpreter probes
need. Point PhpStorm at `/usr/bin/php` for the dispatcher, or at
`/usr/bin/php8.3` (etc.) to pin one version.
