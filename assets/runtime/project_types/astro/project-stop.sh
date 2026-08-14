#!/bin/bash
# project-stop.sh <project-name>
# Run by `mpd stop <project>` for an Astro project.
#
# Prints, and does nothing else. The dev server belongs to the developer,
# not to mpd (see project-setup.sh), so there is nothing here for mpd to
# stop — and reaching in to kill a process it did not start would be the
# same mistake the retired systemd unit made.
#
# What `mpd stop` does mean for an astro project: it records the project
# as stopped. The vhost, certificate and DNS record stay — those are
# `mpd configure`'s and they survive, so the URL keeps resolving.
set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"
ASTRO_BIN="${PROJECT_DIR}/node_modules/.bin/astro"

# node comes from nvm, which this shell does not load on its own: mpd
# runs the script through `podman exec`, not a login shell, so the
# ~/.bashrc that would set it up never runs. Guarded both ways — a
# runtime with no nvm, or a project with no node_modules yet, still gets
# the message below, just without the live status line.
if [ -s "${HOME}/.nvm/nvm.sh" ]; then
    # shellcheck source=/dev/null
    source /opt/mpd/assets/runtime/lib/nvm-env.sh
fi

STATUS=""
if [ -x "$ASTRO_BIN" ] && command -v node >/dev/null 2>&1; then
    cd "${PROJECT_DIR}"
    # `astro dev status` checks the lock file against a live process, so
    # this reports what is actually running rather than what mpd assumes.
    # Never fatal: a project mid-install or with a broken tree still stops.
    # Keep only the lines that report something up: both subcommands
    # always print, so without this a stopped project reports "No preview
    # server is running" as if that were news.
    STATUS=$({ "$ASTRO_BIN" dev status; "$ASTRO_BIN" preview status; } 2>/dev/null \
        | grep "running at" || true)
fi

echo ""
case "$STATUS" in
    *"running at"*)
        echo "$STATUS"
        echo ""
        echo "That server is Astro's, not mpd's — mpd will not stop it for you:"
        echo ""
        echo "    cd ${PROJECT_DIR}"
        echo "    npx astro dev stop            # or: npx astro preview stop"
        echo ""
        echo "One started in the foreground stops with Ctrl-C. Astro 7.2+ also has"
        echo "'npx astro dev --background', with 'dev status' and 'dev logs"
        echo "--follow' alongside 'dev stop' — and it selects background mode on"
        echo "its own when an AI agent is driving the CLI."
        ;;
    *)
        echo "No Astro server is running for '${PROJECT_NAME}' — nothing to stop."
        echo "The URL keeps resolving; it answers again as soon as you start one."
        ;;
esac
