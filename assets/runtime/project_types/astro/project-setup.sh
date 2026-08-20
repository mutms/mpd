#!/bin/bash
# project-setup.sh <project-name>
# Run by `mpd start <project>` for an Astro project.
#
# Prints. That is the whole job.
#
# mpd sets up the caddy frontdoor and nothing else: the vhost, the TLS
# certificate and the DNS record, all written by `mpd start`. The
# server behind them is Astro's own, started and stopped by the developer
# with the commands in Astro's docs.
#
# NOTHING here may run a command inside the project — no `astro`, no
# `npm`, no node. That is not a style preference, it is the bug this file
# was rewritten to fix: `astro dev status` loads astro.config.mjs, which
# spawns a persistent esbuild service that inherits stdout, so capturing
# its output in a command substitution never returns. mpd hung holding
# the state lock, which blocked every other mpd command on the VM.
# Static text cannot hang.
set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"
SERVICE_NAME="mpd-${PROJECT_NAME}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
EFFECTIVE_FILE="/srv/meta/${PROJECT_NAME}/effective.json"

if [ ! -f "$EFFECTIVE_FILE" ]; then
    echo "Error: ${EFFECTIVE_FILE} missing — run mpd start ${PROJECT_NAME} first" >&2
    exit 1
fi

# Exports MPD_ZONE for the message below.
# shellcheck source=/dev/null
source /opt/mpd/assets/runtime/lib/source-mpd-env.sh

# Retire the per-project unit older mpd versions installed. Left enabled
# it restarts on every runtime boot and takes the dev server's port and
# lock file. Idempotent: nothing to do once it is gone.
if [ -f "$SERVICE_FILE" ]; then
    echo "Removing the mpd-managed dev server unit (${SERVICE_NAME}) — Astro's own commands replace it."
    sudo systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
    sudo rm -f "$SERVICE_FILE"
    sudo systemctl daemon-reload
fi

PORT=$(jq -r '.port // 4321' "$EFFECTIVE_FILE")

echo ""
echo "https://${PROJECT_NAME}.${MPD_ZONE}/ is wired up: caddy terminates TLS and"
echo "proxies to localhost:${PORT}. It answers once you start Astro's server:"
echo ""
echo "    cd ${PROJECT_DIR}"
echo "    npm run dev                   # foreground, Ctrl-C to stop"
echo "    npx astro dev --background    # detached; dev status / logs --follow / stop"
echo ""
echo "The port comes from server.port in astro.config.mjs (default 4321)."
echo "Change it there, then re-run: mpd start ${PROJECT_NAME}"
