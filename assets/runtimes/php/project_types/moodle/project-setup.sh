#!/bin/bash
# project-setup.sh <project-name>
# Run by `mpd start <project>` to bring an already-configured Moodle project's
# runtime-side state into a startable shape:
#   - Reads phpVersion / phpFpmPort from /srv/meta/<n>/effective.json (written
#     by scripts/configure.sh during `mpd configure <project>`)
#   - Creates /srv/data/<project-name>/{dataroot,dataroot_behat,dataroot_phpunit}
#   - Writes per-project FPM pool listening on TCP 127.0.0.1:<phpFpmPort>
#     (the Caddy frontdoor sidecar reaches it via pod-shared netns)
# No Apache, no /etc/hosts edits — TLS termination + project routing live in
# the frontdoor sidecar attached to the runtime pod by mpd.
# Per-project TLS certs are at /srv/meta/<n>/cert.pem + key.pem (mpd writes them).
# DB provisioning happens during `mpd configure <project>` — by start time the
# DB container exists and the per-project DB has been created.
set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"
DATAROOT="/srv/data/${PROJECT_NAME}/dataroot"
BEHATDATAROOT="/srv/data/${PROJECT_NAME}/dataroot_behat"
PHPUNITDATAROOT="/srv/data/${PROJECT_NAME}/dataroot_phpunit"
EFFECTIVE_FILE="/srv/meta/${PROJECT_NAME}/effective.json"

# Basic validation
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

# --- Resolve effective settings (configure.sh wrote effective.json) ---
# shellcheck source=/dev/null
source /opt/mpd/assets/runtime-base/lib/source-mpd-env.sh
PHP_VER="${MPD_PHP_VERSION}"
FPM_PORT=$(jq -r '.phpFpmPort // empty' "$EFFECTIVE_FILE")
if [ -z "$FPM_PORT" ]; then
    echo "Error: phpFpmPort not set in ${EFFECTIVE_FILE}" >&2
    exit 1
fi

# --- Per-project data directories ---
# Script runs as the dev user (projectExec --user <dev>); /srv/data is
# dev-owned (set by fileaccess provisioning), so plain mkdir/chmod work.
for DIR in "$DATAROOT" "$BEHATDATAROOT" "$PHPUNITDATAROOT"; do
    mkdir -p "$DIR"
    chmod 02777 "$DIR"
done

touch "${DATAROOT}/php_error.log"
chmod 0666 "${DATAROOT}/php_error.log"

# --- Drop any stale pool for this project under a *different* PHP version ---
# If the project's PHP version changed (e.g. an upgrade bumped Moodle's
# minimum), project-setup previously wrote the pool into the new version's
# pool.d but left the old one behind. That orphan keeps its old listen port
# in the wrong php-fpm — and once that port is reallocated to another project,
# the orphan makes the shared php-fpm fail to bind and start at all, taking
# every project on that version offline (a 502). Remove it and refresh the
# affected service before writing the current pool.
for STALE in /etc/php/*/fpm/pool.d/mpd-"${PROJECT_NAME}".conf; do
    [ -e "$STALE" ] || continue
    STALE_VER=$(printf '%s' "$STALE" | sed -n 's#^/etc/php/\([0-9.]\+\)/.*#\1#p')
    [ "$STALE_VER" = "$PHP_VER" ] && continue
    sudo rm -f "$STALE"
    sudo systemctl reset-failed "php${STALE_VER}-fpm" 2>/dev/null || true
    sudo systemctl reload "php${STALE_VER}-fpm" 2>/dev/null \
        || sudo systemctl restart "php${STALE_VER}-fpm" 2>/dev/null || true
done

# --- Per-project FPM pool (TCP, runs as the dev user) ---
# Caddy sidecar reaches this pool via 127.0.0.1:${FPM_PORT} on the pod's
# shared netns. FPM workers run as the developer user so web and CLI both
# read/write the same project files as the same identity.
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
EOF
    sudo systemctl reload "php${PHP_VER}-fpm" || sudo systemctl restart "php${PHP_VER}-fpm" || true
fi

echo "Project '${PROJECT_NAME}' initialised (PHP ${PHP_VER}, FPM 127.0.0.1:${FPM_PORT}) — https://${PROJECT_NAME}.mpd.test/"
