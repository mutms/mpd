#!/bin/bash
# mpd-env.sh — shared helper sourced by Astro project-type tools.
# Provides: PROJECT, PROJECT_DIR, SERVICE_NAME, and all MPD_* env variables.
# Usage: source /opt/mpd/assets/vm/project_types/astro/scripts/mpd-env.sh

if [[ "$PWD" =~ ^/srv/projects/([^/]+) ]]; then
    PROJECT="${BASH_REMATCH[1]}"
else
    echo "Error: must be run from within a project directory (/srv/projects/<project>/...)" >&2
    exit 1
fi

PROJECT_DIR="/srv/projects/${PROJECT}"
SERVICE_NAME="mpd-${PROJECT}"

# Layered MPD_* config via the whitelist parser, never raw `source`:
# a cloned project's mpd.env must not execute code.
PROJECT_NAME="${PROJECT}"
# shellcheck source=/dev/null
source /opt/mpd/assets/vm/lib/source-mpd-env.sh
