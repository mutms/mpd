#!/bin/bash
# project-setup.sh <project-name>
# Run by `mpd start <project>` after scripts/configure.sh. Creates the
# data directories and writes this project's FPM pool on
# 127.0.0.1:<phpFpmPort>, where the caddy frontdoor reaches it.
set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"
DATAROOT="/srv/data/${PROJECT_NAME}/dataroot"
BEHATDATAROOT="/srv/data/${PROJECT_NAME}/dataroot_behat"
BEHATFAILDUMP="/srv/data/${PROJECT_NAME}/behat_faildump"
PHPUNITDATAROOT="/srv/data/${PROJECT_NAME}/dataroot_phpunit"
EFFECTIVE_FILE="/srv/meta/${PROJECT_NAME}/effective.json"

if ! [[ "$PROJECT_NAME" =~ ^[a-z][a-z0-9]+$ ]]; then
    echo "Error: project name must start with a letter and contain only lowercase letters and digits (min 2 chars)" >&2
    exit 1
fi

if [ ! -d "$PROJECT_DIR" ]; then
    echo "Error: ${PROJECT_DIR} does not exist — run mpd ${PROJECT_NAME} create first" >&2
    exit 1
fi

if [ ! -f "${PROJECT_DIR}/version.php" ] && [ ! -f "${PROJECT_DIR}/public/version.php" ]; then
    echo "Error: ${PROJECT_DIR} does not appear to be a Moodle codebase (no version.php found)" >&2
    exit 1
fi

if [ ! -f "$EFFECTIVE_FILE" ]; then
    echo "Error: ${EFFECTIVE_FILE} missing — run mpd ${PROJECT_NAME} configure first" >&2
    exit 1
fi

# shellcheck source=/dev/null
source /opt/mpd/assets/runtime/lib/source-mpd-env.sh
# Explicit MPD_PHP_VERSION wins; php-configure.sh holds the fallback.
# shellcheck source=/dev/null
. /opt/mpd/assets/runtime/lib/php-configure.sh
PHP_VER="${MPD_PHP_VERSION:-$MPD_PHP_FALLBACK_VERSION}"

# php-install no-ops when the version is present and installs a legacy
# one on demand. A version that cannot install fails start here, not
# as a 502 later.
/opt/mpd/assets/runtime/bin/php-install "$PHP_VER"

FPM_PORT=$(jq -r '.phpFpmPort // empty' "$EFFECTIVE_FILE")
if [ -z "$FPM_PORT" ]; then
    echo "Error: phpFpmPort not set in ${EFFECTIVE_FILE}" >&2
    exit 1
fi

# The script runs as the dev user and /srv/data is dev-owned, so
# plain mkdir/chmod work.
for DIR in "$DATAROOT" "$BEHATDATAROOT" "$BEHATFAILDUMP" "$PHPUNITDATAROOT"; do
    mkdir -p "$DIR"
    chmod 02777 "$DIR"
done

touch "${DATAROOT}/php_error.log"
chmod 0666 "${DATAROOT}/php_error.log"

# Drop a stale pool left under a different PHP version. Once its
# listen port is reallocated, the orphan stops that php-fpm from
# binding at all, taking every project on that version offline (502).
for STALE in /etc/php/*/fpm/pool.d/mpd-"${PROJECT_NAME}".conf; do
    [ -e "$STALE" ] || continue
    STALE_VER=$(printf '%s' "$STALE" | sed -n 's#^/etc/php/\([0-9.]\+\)/.*#\1#p')
    [ "$STALE_VER" = "$PHP_VER" ] && continue
    sudo rm -f "$STALE"
    sudo systemctl reset-failed "php${STALE_VER}-fpm" 2>/dev/null || true
    sudo systemctl reload "php${STALE_VER}-fpm" 2>/dev/null \
        || sudo systemctl restart "php${STALE_VER}-fpm" 2>/dev/null || true
done

# FPM workers run as the dev user, so web and CLI touch project files
# as the same identity. display_errors stays on: a fatal inside
# config.php happens before Moodle can apply $CFG->debugdisplay, and a
# bare 500 hides it. php_admin_* so nothing can switch it back off.
DEV_USER=$(id -un)
FPM_CONF_DIR="/etc/php/${PHP_VER}/fpm/pool.d"
if [ -d "$FPM_CONF_DIR" ]; then
    sudo tee "${FPM_CONF_DIR}/mpd-${PROJECT_NAME}.conf" > /dev/null << EOF
[${PROJECT_NAME}]
listen = 127.0.0.1:${FPM_PORT}
user = ${DEV_USER}
group = ${DEV_USER}
pm = ondemand
pm.max_children = 5
pm.process_idle_timeout = 60s
php_admin_value[error_log] = ${DATAROOT}/php_error.log
php_admin_flag[log_errors] = on
php_admin_flag[display_errors] = on
php_admin_flag[display_startup_errors] = on
php_admin_value[error_reporting] = E_ALL
EOF
    sudo systemctl reload "php${PHP_VER}-fpm" || sudo systemctl restart "php${PHP_VER}-fpm" || true
fi

echo "Project '${PROJECT_NAME}' initialised (PHP ${PHP_VER}, FPM 127.0.0.1:${FPM_PORT}) — https://${PROJECT_NAME}.${MPD_ZONE}/"
