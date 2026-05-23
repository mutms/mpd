#!/bin/bash
# mpd-env.sh — shared helper sourced by Moodle project-type tools.
# Provides: PROJECT, PROJECT_DIR, moodle_run(), and all MPD_* env variables.
# Usage: source /opt/mpd/assets/runtimes/php/project_types/moodle/scripts/mpd-env.sh

# Detect project from current working directory.
if [[ "$PWD" =~ ^/srv/projects/([^/]+) ]]; then
    PROJECT="${BASH_REMATCH[1]}"
else
    echo "Error: must be run from within a project directory (/srv/projects/<project>/...)" >&2
    exit 1
fi

PROJECT_DIR="/srv/projects/${PROJECT}"

# moodle_run <relative-script-path> [args...]
#
# Moodle's source layout shifted between versions. Pre-5.0 keeps everything
# at the project root. 5.0+ moved web entry points under public/ — but it's
# *partial*: in 5.x, admin/cli/* (install_database, cron, upgrade, ...) is
# still at the root, while admin/tool/* (phpunit, behat, ...) moved under
# public/. So MOODLE_DIR-as-a-single-value doesn't work — each script needs
# to be resolved individually.
#
# This helper takes the relative path the tool wants to run (e.g.
# "admin/cli/install_database.php"), checks where it actually lives in the
# current project, cd's there, and execs php on it. The cwd matters because
# Moodle CLIs use require_once(__DIR__/../config.php) etc.
moodle_run() {
    local rel="$1"; shift
    if [ -f "${PROJECT_DIR}/${rel}" ]; then
        cd "${PROJECT_DIR}"
    elif [ -f "${PROJECT_DIR}/public/${rel}" ]; then
        cd "${PROJECT_DIR}/public"
    else
        echo "Error: ${rel} not found under ${PROJECT_DIR} or ${PROJECT_DIR}/public" >&2
        exit 1
    fi
    exec php "$rel" "$@"
}

# Layered MPD_* env via the secure whitelist parser (NOT raw `source` — a
# malicious project's mpd.env with `MPD_FOO=$(rm -rf ~)` would otherwise
# execute when cloned from git). Loads runtime defaults → type defaults →
# /var/lib/mpd/env/mpd-vm.env → project mpd.env, last-assignment-wins.
PROJECT_NAME="${PROJECT}"
# shellcheck source=/dev/null
source /opt/mpd/assets/runtime-base/lib/source-mpd-env.sh
