#!/bin/bash
# mpd-env.sh — shared helper sourced by Astro project-type tools.
# Provides: PROJECT, PROJECT_DIR, SERVICE_NAME, and all MPD_* env variables.
# Usage: source /opt/mpd/assets/runtime/project_types/astro/scripts/mpd-env.sh

# Detect project from current working directory.
if [[ "$PWD" =~ ^/srv/projects/([^/]+) ]]; then
    PROJECT="${BASH_REMATCH[1]}"
else
    echo "Error: must be run from within a project directory (/srv/projects/<project>/...)" >&2
    exit 1
fi

PROJECT_DIR="/srv/projects/${PROJECT}"
SERVICE_NAME="mpd-${PROJECT}"

# Layered MPD_* env via the secure whitelist parser (NOT raw `source` — a
# malicious project's mpd.env with `MPD_FOO=$(rm -rf ~)` would otherwise
# execute when cloned from git). Loads runtime defaults → type defaults →
# /var/lib/mpd/env/mpd-virt.env → project mpd.env, last-assignment-wins.
PROJECT_NAME="${PROJECT}"
# shellcheck source=/dev/null
source /opt/mpd/assets/runtime/lib/source-mpd-env.sh
