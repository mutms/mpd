#!/bin/bash
# project-delete.sh <project-name>
# Run by `mpd delete <project>` (astro type). Removes the per-project
# dev-server unit older mpd versions installed. The source tree is
# dev-owned; its removal happens host-side, in mpd.
set -euo pipefail

PROJECT_NAME="$1"
SERVICE_NAME="mpd-${PROJECT_NAME}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

if [ -f "$SERVICE_FILE" ]; then
    sudo systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
    sudo rm -f "${SERVICE_FILE}"
    sudo systemctl daemon-reload
    echo "Removed the legacy dev server unit for '${PROJECT_NAME}'."
fi

echo "Source kept in /srv/projects/${PROJECT_NAME}/"
