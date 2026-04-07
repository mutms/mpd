#!/bin/bash
# project-delete.sh <project-name>
# Tears down per-project runtime-side state for a Moodle project:
#   - Per-project FPM pool config (/etc/php/<ver>/fpm/pool.d/mpd-<n>.conf)
#   - config-mpd.php (config.php is dev-owned and kept; it only sources config-mpd.php)
#
# The Caddy frontdoor sidecar handles TLS termination + routing; nothing
# in /etc/apache2/, /etc/hosts, or systemd is owned by the runtime.
# DNS for *.mpd.test is served by the dnsmasq service (out-of-runtime).
# DB drop and source-tree removal happen on the host side via Swift.
# Called by mpd delete <project>.
set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"

# --- Per-project FPM pool configs ---
for POOL in /etc/php/*/fpm/pool.d/mpd-"${PROJECT_NAME}".conf; do
    [ -f "$POOL" ] || continue
    sudo rm -f "$POOL"
    VER=$(echo "$POOL" | grep -oE '[0-9]+\.[0-9]+')
    sudo systemctl reload "php${VER}-fpm" 2>/dev/null || true
done

# --- config-mpd.php only (config.php is dev-owned, kept) ---
rm -f "${PROJECT_DIR}/config-mpd.php"
