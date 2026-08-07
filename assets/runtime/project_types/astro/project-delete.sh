#!/bin/bash
# project-delete.sh <project-name>
# Stops and removes the per-project systemd unit for the Astro dev server.
# Source files and node_modules are kept (the source tree is dev-owned and
# may have local work; deletion happens on the host side, in mpd).
#
# The in-runtime caddy frontdoor handles TLS termination + routing; nothing
# in /etc/apache2/, /etc/hosts, or anywhere else is owned by the runtime
# for this project. DNS is served by the out-of-runtime dnsmasq service.
# Called by mpd delete <project> (astro type).
set -euo pipefail

PROJECT_NAME="$1"
SERVICE_NAME="mpd-${PROJECT_NAME}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# --- Systemd service ---
if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    echo "Stopping ${SERVICE_NAME}..."
    sudo systemctl stop "${SERVICE_NAME}"
fi

if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
    sudo systemctl disable "${SERVICE_NAME}"
fi

sudo rm -f "${SERVICE_FILE}"
sudo systemctl daemon-reload

echo "Dev server for '${PROJECT_NAME}' stopped and disabled."
echo "Source kept in /srv/projects/${PROJECT_NAME}/"
