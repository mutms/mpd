# `php` runtime

PHP 8.1–8.5 with FPM, Composer, Node.js (nvm), DB clients (postgres,
mariadb, mysql).

- **`build.sh`** — installs PHP via the Sury repo, configures FPM
  pools, installs Composer + Node, sets up `/usr/local/bin/php` as a
  project-aware version dispatcher.
- **`tools/`** — `composer-install`, `composer-upgrade`, the `php`
  wrapper.
- **`project_types/moodle/`** — Moodle support: `phpunit`, `behat`,
  `mdl-cron`, `mdl-cache-purge`, `mdl-install`, `mdl-upgrade`, `grunt`,
  `mpci` / `mpci-install`, `mdl-data-purge`. See `docs/{desktop,machine}/USAGE.md`
  for the full per-tool table.

PHP version is resolved per project from the layered MPD_PHP_VERSION
(runtime default → type default → user → project) — see the `php`
wrapper and `source-mpd-env.sh`.
