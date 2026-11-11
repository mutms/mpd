#!/bin/bash
# project-delete.sh <project-name>
# Run by `mpd delete <project>`. Removes this project's FPM pools.
set -euo pipefail

PROJECT_NAME="$1"

for POOL in /etc/php/*/fpm/pool.d/mpd-"${PROJECT_NAME}".conf; do
    [ -f "$POOL" ] || continue
    sudo rm -f "$POOL"
    VER=$(echo "$POOL" | grep -oE '[0-9]+\.[0-9]+')
    sudo systemctl reload "php${VER}-fpm" 2>/dev/null || true
done
