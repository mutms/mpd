#!/bin/bash
# project-delete.sh <project-name>
# Run by `mpd delete <project>`. Removes this project's FPM pools and
# config-mpd.php. DB drop and source-tree removal happen host-side, in
# mpd.
set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"

for POOL in /etc/php/*/fpm/pool.d/mpd-"${PROJECT_NAME}".conf; do
    [ -f "$POOL" ] || continue
    sudo rm -f "$POOL"
    VER=$(echo "$POOL" | grep -oE '[0-9]+\.[0-9]+')
    sudo systemctl reload "php${VER}-fpm" 2>/dev/null || true
done

# config.php is dev-owned and kept; it only sources config-mpd.php.
rm -f "${PROJECT_DIR}/config-mpd.php"
