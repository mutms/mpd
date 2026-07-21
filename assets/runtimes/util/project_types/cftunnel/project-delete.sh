#!/bin/bash
# project-delete.sh <project-name>
# cftunnel project type — runs at `mpd delete <project>`.
# Stop + disable + remove the systemd unit. The project directory is
# wiped by mpd after this script returns.

set -euo pipefail

PROJECT_NAME="$1"
SERVICE_NAME="mpd-${PROJECT_NAME}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

if [ -f "$SERVICE_FILE" ]; then
    sudo systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    sudo systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    sudo rm -f "$SERVICE_FILE"
    sudo systemctl daemon-reload
    echo "Removed systemd unit ${SERVICE_FILE}"
else
    echo "No systemd unit found for ${PROJECT_NAME}; nothing to remove."
fi

echo "cftunnel '${PROJECT_NAME}' delete complete."
