#!/bin/bash
# project-setup.sh <project-name>
# Run by `mpd start <project>` for a static site. There is no server to
# start and nothing to install: caddy already serves the files. This only
# says where they are being served from.
set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"
EFFECTIVE_FILE="/srv/meta/${PROJECT_NAME}/effective.json"

if [ ! -f "$EFFECTIVE_FILE" ]; then
    echo "Error: ${EFFECTIVE_FILE} missing — run mpd start ${PROJECT_NAME} first" >&2
    exit 1
fi

# shellcheck source=/dev/null
source /opt/mpd/assets/vm/lib/source-mpd-env.sh

ROOT=$(jq -r '.docroot // empty' "$EFFECTIVE_FILE")

echo ""
echo "https://${PROJECT_NAME}.${MPD_ZONE}/ serves ${ROOT}"
echo ""
echo "Files are served where they are - edit and reload, there is nothing to rebuild."
echo "To publish a subdirectory instead, set MPD_DOCROOT in ${PROJECT_DIR}/mpd.env"
echo "and run: mpd start ${PROJECT_NAME}"
