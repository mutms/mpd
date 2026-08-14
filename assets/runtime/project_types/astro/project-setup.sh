#!/bin/bash
# project-setup.sh <project-name>
# Run by `mpd start <project>` for an Astro project.
#
# mpd does NOT run the dev server. Astro already has a lifecycle the
# developer knows from its own docs (`npm run dev`, `astro dev`,
# `astro dev stop`), and a second one owned by mpd only competes with it:
# the two fight over the same port and the same .astro/dev.json lock, and
# a developer who starts one the documented way gets a crash-looping unit
# they never asked for.
#
# What is addressable is set up by `mpd configure <project>` instead —
# caddy vhost (urls.json), TLS cert, DNS. Those hold whether or not a
# dev server happens to be up, so the URL works the moment one is.
#
# All this script does is retire the unit older versions installed, and
# say how to start the server.
set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"
SERVICE_NAME="mpd-${PROJECT_NAME}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
EFFECTIVE_FILE="/srv/meta/${PROJECT_NAME}/effective.json"

if [ ! -d "$PROJECT_DIR" ]; then
    echo "Error: ${PROJECT_DIR} does not exist — clone the project first" >&2
    exit 1
fi
if [ ! -f "${PROJECT_DIR}/package.json" ]; then
    echo "Error: ${PROJECT_DIR}/package.json not found — is this an Astro/Node project?" >&2
    exit 1
fi
if [ ! -f "$EFFECTIVE_FILE" ]; then
    echo "Error: ${EFFECTIVE_FILE} missing — run mpd configure ${PROJECT_NAME} first" >&2
    exit 1
fi

# Exports MPD_ZONE for the message below.
# shellcheck source=/dev/null
source /opt/mpd/assets/runtime/lib/source-mpd-env.sh

# Retire the per-project unit older mpd versions installed. Left enabled
# it restarts on every runtime boot and takes the dev server's port and
# lock, so a plain `npm run dev` fails with "Another astro dev server is
# already running". Idempotent: nothing to do once it is gone.
if [ -f "$SERVICE_FILE" ]; then
    echo "Removing the mpd-managed dev server unit (${SERVICE_NAME}) — Astro's own commands replace it."
    sudo systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
    sudo rm -f "$SERVICE_FILE"
    sudo systemctl daemon-reload
fi

PORT=$(jq -r '.port // 4321' "$EFFECTIVE_FILE")
ASTRO_BIN="${PROJECT_DIR}/node_modules/.bin/astro"

# node comes from nvm, which this shell does not load on its own — mpd
# runs the script through `podman exec`, not a login shell. Guarded, so
# a runtime with no nvm still reaches the message below.
if [ -s "${HOME}/.nvm/nvm.sh" ]; then
    # shellcheck source=/dev/null
    source /opt/mpd/assets/runtime/lib/nvm-env.sh
fi

STATUS=""
if [ -x "$ASTRO_BIN" ] && command -v node >/dev/null 2>&1; then
    cd "${PROJECT_DIR}"
    STATUS=$("$ASTRO_BIN" dev status 2>/dev/null || true)
fi

echo ""
# Both subcommands exit 0 whether or not a server is up, so the output is
# what carries the answer. Matching a phrase is a guess about someone
# else's wording — hence the fallback branch is the useful one: if Astro
# ever rephrases this, the developer gets the start instructions, which
# is the harmless way to be wrong.
case "$STATUS" in
    *"running at"*)
        echo "$STATUS"
        echo "https://${PROJECT_NAME}.${MPD_ZONE}/ is live — caddy proxies it to localhost:${PORT}."
        echo ""
        echo "That server is Astro's, not mpd's. To stop it:"
        echo "    cd ${PROJECT_DIR} && npx astro dev stop"
        ;;
    *)
        echo "'${PROJECT_NAME}' is served at https://${PROJECT_NAME}.${MPD_ZONE}/ once its dev server runs."
        echo "mpd does not run it — start it the way the Astro docs do, from"
        echo "inside the runtime:"
        echo ""
        echo "    cd ${PROJECT_DIR}"
        echo "    npm run dev                   # foreground, Ctrl-C to stop"
        echo "    npx astro dev --background    # detached; dev status / logs --follow / stop"
        echo ""
        echo "caddy terminates TLS and proxies to localhost:${PORT}, which is where"
        echo "a default 'astro dev' listens. Set server.port in astro.config.mjs to"
        echo "change it, then re-run: mpd configure ${PROJECT_NAME}"
        ;;
esac
