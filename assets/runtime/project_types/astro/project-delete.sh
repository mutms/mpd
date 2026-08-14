#!/bin/bash
# project-delete.sh <project-name>
# Retires the per-project systemd unit older mpd versions installed for the
# Astro dev server. Source files and node_modules are kept (the source tree
# is dev-owned and may have local work; deletion happens on the host side,
# in mpd).
#
# mpd no longer runs a dev server, so on a current install there is usually
# nothing here to do — a dev server the developer started is theirs to stop
# (`astro dev stop`), and it is not a service mpd can or should reach into.
#
# The in-runtime caddy frontdoor handles TLS termination + routing; nothing
# in /etc/apache2/, /etc/hosts, or anywhere else is owned by the runtime
# for this project. DNS is served by the out-of-runtime dnsmasq service.
# Called by mpd delete <project> (astro type).
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
