# `php` runtime

PHP 8.1–8.5 with FPM, Composer, Node.js (nvm), DB clients (postgres,
mariadb, mysql).

- **`build.sh`** — installs PHP via the Sury repo, configures FPM
  pools, installs Composer + Node, and registers the `php` wrapper as
  the Debian `php` alternative (priority 1000, pinned) so
  `/usr/bin/php` is the project-aware version dispatcher.
- **`tools/`** — `composer-install`, `composer-upgrade`, the `php`
  wrapper.
- **`project_types/moodle/`** — Moodle support: `phpunit`, `behat`,
  `mdl-cron`, `mdl-cache-purge`, `mdl-install`, `mdl-upgrade`, `grunt`,
  `mpci` / `mpci-install`, `mdl-data-purge`. See `docs/USAGE.md`
  for the full per-tool table.

PHP version is resolved per project from the layered MPD_PHP_VERSION
(runtime default → type default → user → project) — see the `php`
wrapper and `source-mpd-env.sh`. Outside `/srv/projects/<n>/` it falls
back to a pinned version (8.2), so `php -v` from `$HOME`
always answers the same thing — which is what IDE interpreter probes
need. Point PhpStorm at `/usr/bin/php` for the dispatcher, or at
`/usr/bin/php8.3` (etc.) to pin one version.
