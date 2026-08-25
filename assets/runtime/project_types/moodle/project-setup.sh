#!/bin/bash
# project-setup.sh <project-name>
# Run by `mpd start <project>` to bring an already-configured Moodle project's
# runtime-side state into a startable shape:
#   - Reads phpVersion / phpFpmPort from /srv/meta/<n>/effective.json (written
#     by scripts/configure.sh during `mpd start <project>`)
#   - Creates /srv/data/<project-name>/{dataroot,dataroot_behat,behat_faildump,dataroot_phpunit}
#   - Writes per-project FPM pool listening on TCP 127.0.0.1:<phpFpmPort>
#     (the in-runtime caddy frontdoor reaches it on localhost)
# No Apache, no /etc/hosts edits — TLS termination + project routing live in
# the in-runtime caddy frontdoor (mpd-caddy.service).
# Per-project TLS certs are at /srv/meta/<n>/cert.pem + key.pem (mpd writes them).
# DB provisioning happens during `mpd start <project>` — by start time the
# DB container exists and the per-project DB has been created.
set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"
DATAROOT="/srv/data/${PROJECT_NAME}/dataroot"
BEHATDATAROOT="/srv/data/${PROJECT_NAME}/dataroot_behat"
BEHATFAILDUMP="/srv/data/${PROJECT_NAME}/behat_faildump"
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
source /opt/mpd/assets/runtime/lib/source-mpd-env.sh
PHP_VER="${MPD_PHP_VERSION}"

# The current PHP versions are baked into the image; a legacy one this
# project asks for is installed on demand. php-install is idempotent and
# no-ops instantly for a version already present, so this is cheap on the
# common path. A version that cannot be installed fails start loudly here,
# rather than silently skipping the FPM pool below into a 502.
/opt/mpd/assets/runtime/bin/php-install "$PHP_VER"

FPM_PORT=$(jq -r '.phpFpmPort // empty' "$EFFECTIVE_FILE")
if [ -z "$FPM_PORT" ]; then
    echo "Error: phpFpmPort not set in ${EFFECTIVE_FILE}" >&2
    exit 1
fi

# --- Per-project data directories ---
# Script runs as the dev user (projectExec --user <dev>); /srv/data is
# dev-owned (set by volume provisioning), so plain mkdir/chmod work.
for DIR in "$DATAROOT" "$BEHATDATAROOT" "$BEHATFAILDUMP" "$PHPUNITDATAROOT"; do
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
# The caddy frontdoor reaches this pool via 127.0.0.1:${FPM_PORT} on the
# container loopback. FPM workers run as the developer user so web and CLI both
# read/write the same project files as the same identity.
#
# Errors are always displayed in the response body. This is a development
# environment: a bare 500 with an empty body tells the developer nothing,
# and the failures that matter most — anything fatal inside config.php —
# happen *before* Moodle's setup.php gets to apply $CFG->debugdisplay, so
# relying on Moodle's own error handling loses exactly the errors that are
# hardest to diagnose. php_admin_* (not php_value) so nothing downstream
# can switch it back off mid-request.
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
