# Moodle development in an mpd VM — guide for AI agents

Read this before working on a Moodle project or plugin under
`/srv/projects/<project>/`. It is the short, task-ordered version of what an
AI agent needs. The owning docs carry the detail: [`usage.md`](usage.md) for
tools, backups and `mpd reset`; [`debugging.md`](debugging.md) for symptoms.
Do not copy their content here — link to it.

## What you are working in

- The VM is disposable. Project databases and dataroots can be wiped,
  reseeded or edited with direct SQL. Source trees are not disposable —
  see "Git" below.
- Chromium (`/usr/bin/chromium`, usable headless) is present only after
  the developer has run `gnome-install`. Check with `command -v chromium`
  before relying on it; if it is missing, ask the developer to run
  `gnome-install` rather than installing a browser yourself.
- To log in through a browser, open the URL that `mdl-agent-login
  [username]` prints. Never reset or change a password to get in, least
  of all `admin`'s: the developer uses that account and would be locked
  out. `/srv/data/<project>/agent/` is yours for scratch files. See
  [`usage.md` → "Agent route"](usage.md#agent-route-mdl-agent).
- Several projects sit side by side under `/srv/projects/`. Each has its
  own database, dataroot (`/srv/data/<project>/`), PHP version and URL
  `https://<project>.<NNN>.mpd.test/`. Use a second project for an old
  code state instead of switching branches in the first one.
- Ask mpd for facts, do not read its state files:
  `mpd status <project> --json` (engine, host, data directory, URLs).
- Per-project settings are in `/srv/projects/<project>/mpd.env`
  (`MPD_DB`, `MPD_PHP_VERSION`, `MPD_MOODLE_BEHAT`,
  `MPD_REQUIRE_SERVICES`). Apply a change with `mpd start <project>`.
- Moodle 5.1+ trees keep the web root in `public/`; plugins are under
  `public/…`, while `config.php`, `vendor/` and `phpunit.xml` stay at the
  project root. The tools below handle both layouts.

## Tools

Run them from anywhere inside the project tree. Full list and options:
[`usage.md` → "Tools available in the VM"](usage.md#tools-available-in-the-vm).

| Task | Command |
|---|---|
| Install the site | `mdl-install` |
| Upgrade the database after a code change | `mdl-upgrade` |
| Purge caches / run cron once | `mdl-cache-purge` / `mdl-cron` |
| Log a browser in, as any user | `mdl-agent-login [username]` prints a single-use URL |
| Run PHP with Moodle loaded | `mdl-agent-php '<code>'`, a `.php` file, or `-` for stdin; `--user=<username>` |
| Query the site database | `mdl-agent-sql 'SELECT … FROM {user}'` (`--json`, `--tsv`, `--limit`); `--write` to change data |
| Run a plugin's upgrade steps again | `mdl-agent-downgrade <plugin> <version>`, then `mdl-upgrade`; the database is not rolled back |
| See what earlier sessions did to the site | `mdl-agent-log [n]` lists the logged `mdl-agent-*` calls |
| See a page as a user | `mdl-agent-screenshot [--user=<username>] /local/path` prints the PNG's path; read the image |
| Save / restore database + dataroot | `mdl-data-backup [name]` / `mdl-data-restore <name>` (`--list`) |
| PHPUnit | `phpunit-init`, then `phpunit --testsuite <component>_testsuite` or `phpunit <path to test file>` |
| Behat | `behat-init`, then `behat --tags=@<component>` or `behat <path to feature>`. Three more independent sites: `behat1-init` / `behat1`, `behat2-init` / `behat2`, `behat3-init` / `behat3` |
| Code checks | `mpci-install` once, then `mpci <command> <plugin dir>` |
| JS build | `grunt` |

Prefer these wrappers over calling `vendor/bin/phpunit`, `vendor/bin/behat`
or `admin/cli/*.php` directly: they find the project root, pick the
project's PHP version and pass the Behat config path.

### Code checks with mpci

`mpci` is moodle-plugin-ci. It is not installed until you run
`mpci-install`. The checks a plugin's CI workflow runs, usable locally
without installing the plugin into a CI site:

```bash
mpci phplint <plugin dir>
mpci phpcs --max-warnings 0 <plugin dir>
mpci phpdoc --max-warnings 0 <plugin dir>
mpci validate <plugin dir>
mpci savepoints <plugin dir>
mpci mustache <plugin dir>
```

`vendor/bin/phpcs` does not exist in a project; `mpci phpcs` is the code
style check. `mpci mustache` reports "Problem calling HTML validator" when
the validator is not reachable from the VM; that is the environment, not
the template.

## Traps

- **`mpd reset <project>` destroys the PHPUnit and Behat sites too.** They
  live in the same database under their own table prefixes, and their
  dataroots are under `/srv/data/<project>/`. After a reset and reinstall
  or restore, run `phpunit-init` and `behat-init` again. Never reset while
  a test run is in progress, including a run started by another agent.
- **`mdl-data-restore` only writes into an empty project.** The sequence is
  `mpd reset <project> --yes`, `mpd start <project>`,
  `mdl-data-restore <name>`, then `mdl-upgrade` when the code differs from
  the backup's.
- **A restore does not include the PHPUnit or Behat sites.** Leftover test
  tables from an interrupted run make `phpunit-init` fail with "Can not
  install on non-test site". Drop the tables with the test prefix, then
  init again.
- **Backups are engine-specific.** A bundle restores only into the same
  engine, same or newer major version. To test another engine, set
  `MPD_DB` in `mpd.env`, `mpd start`, install and seed again.
- **One PHPUnit run per project at a time, and one Behat run per Behat
  site.** There is a single PHPUnit site. There are four independent
  Behat sites (`behat`, `behat1`, `behat2`, `behat3`, each with its own
  `-init`), so several Behat runs can go at once, one in each; never
  start a second run in a site that is busy. Do not change `version.php`,
  `db/install.xml` or `db/access.php` under a running Behat run: all
  four sites share the code, so each then demands an upgrade and later
  scenarios fail.
- **Re-init after schema or version changes.** `phpunit-init` after
  changing `db/install.xml`, `version.php` or adding a plugin;
  `behat-init` after the same, and after adding Behat step definitions
  (`behat1-init`, `behat2-init`, `behat3-init` for the other sites, only
  when used).
- **Behat needs `MPD_MOODLE_BEHAT=1`.** It is off by default because the
  Selenium image is large. Enable it with
  `mpd start <project> MPD_MOODLE_BEHAT=1`. Fail dumps are in
  `/srv/data/<project>/behat_faildump/` (`behat_faildump1/` to
  `behat_faildump3/` for the other sites).
- **Follow a Behat run in its log.** `/srv/data/<project>/behat_error.log`
  (`behat1_error.log` to `behat3_error.log`) gets every scenario's start
  and end, each failed step and all PHP errors as they happen. Read it
  instead of waiting for a long run to finish.
- **A new `.feature` file needs `behat-util --enable`** (a few seconds,
  `behat1-util` to `behat3-util` for the other sites) before a site can
  run it; a full `behat-init` is only needed after version, schema or
  step definition changes.
- **No DDL in normal PHPUnit tests.** Moodle resets data between tests,
  not schema. Test an upgrade step by upgrading a real site (next
  section), not by recreating old tables in a test.

## Testing a database upgrade

Upgrade steps cannot be covered by PHPUnit, so run them against real data.

1. **Get a site on the old code.** Use a separate project that stays on
   the pre-change branch (for example `<project>b`), or a project on the
   previous stable release. Do not switch branches in the working project
   to get there.
2. **Seed it.** Write a throwaway CLI script outside the source tree that
   requires the project's `config.php` and creates the cases through the
   old code's own API. Add broken rows (orphans, missing contexts) with
   direct SQL. Cover every branch of the upgrade step, including the rows
   it must skip.
3. **Back it up:** `mdl-data-backup <name>` in that project.
4. **Restore into the project with the new code and upgrade:**

   ```bash
   cd /srv/projects/<project>
   mpd reset <project> --yes
   mpd start <project>
   mdl-data-restore <name>
   mdl-upgrade
   ```

5. **Inspect** the result with a second throwaway script or SQL: migrated
   rows, skipped rows, dropped tables and fields, plugin versions.
6. **Repeat from step 4** after each fix; the bundle is reusable.
7. Run `phpunit-init` / `behat-init` again before going back to tests.

Test both ways a site can arrive at the new version when they differ: a
plugin that is upgraded runs `db/upgrade.php` from its old version; a
plugin that is newly installed gets the latest `db/install.xml` and
`db/install.php` only. Moodle upgrades plugins of one type in alphabetical
order; `$plugin->dependencies` guarantees presence and minimum version,
not order.

## Git

- Many trees are assembled by `mudev` from a recipe (`.mudev.json`): the
  Moodle checkout is one repository and each added plugin is its own
  nested repository, excluded from the outer one. Run git per plugin:
  `git -C <plugin dir> status`. `git status` at the project root does not
  show plugin changes.
- Unless the developer says otherwise: do not commit, stage, stash or
  switch branches. Leave changes in the working trees for review. Use
  plain `rm` and `mv`, not `git rm` / `git mv`, because those stage.
- Follow the plugin's own `AGENTS.md` when it has one (MuTMS plugins: see
  `tool_mulib/AGENTS.md` in the project tree) for coding conventions,
  copyright headers and who bumps versions.

## Working with several agents

- Give exactly one agent the PHPUnit site, and each Behat site (`behat`,
  `behat1`, `behat2`, `behat3`) to at most one agent, and say so in each
  brief.
- **Which Behat site an agent uses.** `behat` belongs to the developer.
  Run `behat-status` and take the highest free numbered site: `behat3`
  first, then `behat2`, then `behat1`. Initialise it with its own
  `-init` if `behat-status` says so. Use `behat` only when the developer
  asks for it, and never start a run in a site shown as BUSY.
- Tell every agent that `mpd reset` and `mdl-data-restore` are off limits
  unless it owns the whole project for that step.
- Scratch scripts, seed data and logs go outside the source tree.
