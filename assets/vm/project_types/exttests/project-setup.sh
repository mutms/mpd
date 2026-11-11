#!/bin/bash
# project-setup.sh <project-name>
# Run by `mpd start <project>`. Writes the PHP-FPM pool that runs the
# test scripts.
set -euo pipefail

PROJECT_NAME="$1"
EFFECTIVE_FILE="/srv/meta/${PROJECT_NAME}/effective.json"

if [ ! -f "$EFFECTIVE_FILE" ]; then
    echo "Error: ${EFFECTIVE_FILE} missing — run mpd start ${PROJECT_NAME} first" >&2
    exit 1
fi

# shellcheck source=/dev/null
source /opt/mpd/assets/vm/lib/source-mpd-env.sh

PHP_VER=$(jq -r '.phpVersion' "$EFFECTIVE_FILE")
FPM_PORT=$(jq -r '.phpFpmPort' "$EFFECTIVE_FILE")

# A pool left under another PHP version would keep the port and stop
# that php-fpm from starting.
for STALE in /etc/php/*/fpm/pool.d/mpd-"${PROJECT_NAME}".conf; do
    [ -e "$STALE" ] || continue
    STALE_VER=$(printf '%s' "$STALE" | sed -n 's#^/etc/php/\([0-9.]\+\)/.*#\1#p')
    [ "$STALE_VER" = "$PHP_VER" ] && continue
    sudo rm -f "$STALE"
    sudo systemctl reset-failed "php${STALE_VER}-fpm" 2>/dev/null || true
    sudo systemctl reload "php${STALE_VER}-fpm" 2>/dev/null \
        || sudo systemctl restart "php${STALE_VER}-fpm" 2>/dev/null || true
done

DEV_USER=$(id -un)
sudo tee "/etc/php/${PHP_VER}/fpm/pool.d/mpd-${PROJECT_NAME}.conf" > /dev/null << POOL
[${PROJECT_NAME}]
listen = 127.0.0.1:${FPM_PORT}
user = ${DEV_USER}
group = ${DEV_USER}
pm = ondemand
pm.max_children = 4
pm.process_idle_timeout = 60s
php_admin_flag[log_errors] = on
php_admin_flag[display_errors] = on
POOL
sudo systemctl reload "php${PHP_VER}-fpm" || sudo systemctl restart "php${PHP_VER}-fpm"

echo ""
echo "Moodle external test files (PHP ${PHP_VER}, FPM 127.0.0.1:${FPM_PORT}):"
echo "  http://${PROJECT_NAME}.${MPD_ZONE}/"
echo "  https://${PROJECT_NAME}.${MPD_ZONE}/"
