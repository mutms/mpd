#!/bin/bash
# configure.sh <project-name>
# Idempotent project repair/configuration for Moodle. Run by
# `mpd configure <project>` after mpd has applied any KEY=VALUE mutations
# to /srv/projects/<project>/mpd.env.
#
# Responsibilities:
#   - Re-apply this type's template/ (seeds any file added to it since the
#     project was created; existing files untouched) and refresh the git
#     excludes for template/ + generated/
#   - Source layered mpd.env (/var/lib/mpd/env/mpd-virt.env then project mpd.env)
#   - Resolve MPD_DB to dbTag/dbEngine/databaseId for downstream use
#   - Fix ownership of /srv/projects/<project>
#   - Ensure dataroot dirs (plus the behat faildump dir) exist with expected perms
#   - Regenerate config-mpd.php (when MPD_DB is set + Moodle source detected)
#   - Allocate FPM port
#   - Emit /srv/meta/<project>/urls.json + effective.json
#
# mpd reads effective.json's dbTag (and re-sanitises) to provision the DB
# container. dbTag empty (or missing) means "no DB for this project".
set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"
DATAROOT="/srv/data/${PROJECT_NAME}/dataroot"
BEHATDATAROOT="/srv/data/${PROJECT_NAME}/dataroot_behat"
BEHATFAILDUMP="/srv/data/${PROJECT_NAME}/behat_faildump"
PHPUNITDATAROOT="/srv/data/${PROJECT_NAME}/dataroot_phpunit"
TYPE_DIR="/opt/mpd/assets/runtime/project_types/moodle"

if [ ! -d "$PROJECT_DIR" ]; then
    echo "Error: ${PROJECT_DIR} does not exist — run mpd ${PROJECT_NAME} create first" >&2
    exit 1
fi

# Re-apply template/ before anything reads mpd.env: a project created before a
# template file existed picks it up here, and mpd.env is guaranteed present for
# source-mpd-env.sh below.
# shellcheck source=/dev/null
. /opt/mpd/assets/runtime/lib/project-template.sh
apply_project_template "$PROJECT_NAME" "$TYPE_DIR"

# /srv/meta/<project>/ holds urls.json + effective.json (read by mpd, the
# in-runtime caddy frontdoor, and the FPM provisioner) plus
# cert.pem/key.pem/project.json that mpd writes from the VM as the dev
# user. /srv/meta is dev-owned (mode 0775) by volume provisioning, so
# plain mkdir works.
mkdir -p "/srv/meta/${PROJECT_NAME}"

# Layered config: /var/lib/mpd/env/mpd-virt.env (bind-mounted RO), then per-project
# /srv/projects/<n>/mpd.env. Project wins; explicit empty in project blocks
# user-level fall-through; absent key in project falls through.
# shellcheck source=/dev/null
source /opt/mpd/assets/runtime/lib/source-mpd-env.sh

# --- Resolve effective settings ---
PHP_VER="${MPD_PHP_VERSION}"
BEHAT="${MPD_MOODLE_BEHAT}"

# Install a legacy PHP version on demand — the current set is baked into the
# image, older EOL versions arrive only when a project asks for one. Done at
# configure time too (not just start) so CLI tools like mdl-install run on the
# project's real version instead of the php wrapper's fallback. Idempotent and
# instant when the version is already present.
/opt/mpd/assets/runtime/tools/php-install "$PHP_VER"

# MPD_DB (docker tag form): "postgres", "postgres:17", "postgres:latest", or
# "" (empty = no DB). Bare engine expands to engine:latest. mpd re-validates
# on the read side, so this script can be lenient about edge cases.
DB_TAG="${MPD_DB:-}"
DB_ENGINE=""
DB_VERSION=""
DATABASE_ID=""
DBTYPE=""
if [ -n "$DB_TAG" ]; then
    case "$DB_TAG" in
        *:*) DB_ENGINE="${DB_TAG%%:*}" ; DB_VERSION="${DB_TAG#*:}" ;;
        *)   DB_ENGINE="$DB_TAG"       ; DB_VERSION="latest"       ;;
    esac
    # Container/dataDir-friendly id: dots in version → dashes.
    DATABASE_ID="${DB_ENGINE}-${DB_VERSION//./-}"
    case "$DB_ENGINE" in
        postgres) DBTYPE="pgsql" ;;
        mariadb)  DBTYPE="mariadb" ;;
        mysql)    DBTYPE="mysqli" ;;
        *)
            echo "Error: unknown DB engine '${DB_ENGINE}' from MPD_DB='${DB_TAG}'" >&2
            exit 1
            ;;
    esac
fi

# --- Ensure Moodle data directories ---
# Script runs as the dev user (projectExec --user <dev>); /srv/data is
# dev-owned (set by volume provisioning), so plain mkdir/chmod work.
for DIR in "$DATAROOT" "$BEHATDATAROOT" "$BEHATFAILDUMP" "$PHPUNITDATAROOT"; do
    mkdir -p "$DIR"
    chmod 02777 "$DIR"
done

touch "${DATAROOT}/php_error.log"
chmod 0666 "${DATAROOT}/php_error.log"

# --- Enabled extra services (written by mpd on every service change) ---
# Absent file or absent name both mean "not enabled" — a fresh volume
# behaves correctly with no services.json at all.
_service_enabled() {
    jq -e --arg s "$1" '.enabled | index($s) != null' /srv/meta/services.json >/dev/null 2>&1
}

# Mail: with mailpit enabled Moodle sends freely into the black hole;
# without it, noemailever guarantees no real mail can ever leave a dev
# project. One line either way, so the sed below stays single-line.
if _service_enabled mailpit; then
    MAIL_CONFIG="\$CFG->smtphosts = 'mailpit.svc.${MPD_ZONE}:1025';"
else
    MAIL_CONFIG="\$CFG->noemailever = true; // no mailpit service enabled"
fi

# --- Render config-mpd.php (only when Moodle source + DB are both present) ---
# Its companion config.php is a static file — template/ seeds it, so it is
# already in place (and left alone if the developer has edited it).
if [ -n "$DATABASE_ID" ] && \
   { [ -f "${PROJECT_DIR}/version.php" ] || [ -f "${PROJECT_DIR}/public/version.php" ]; }; then
    sed \
        -e "s|%%PROJECT%%|${PROJECT_NAME}|g" \
        -e "s|%%DBTYPE%%|${DBTYPE}|g" \
        -e "s|%%DBHOST%%|${DATABASE_ID}.db.${MPD_ZONE}|g" \
        -e "s|%%ZONE%%|${MPD_ZONE}|g" \
        -e "s|%%MAIL_CONFIG%%|${MAIL_CONFIG}|" \
        -e "s|%%SELENIUM_WD_HOST%%|http://seleniumv1.svc.${MPD_ZONE}:4444/wd/hub|" \
        "${TYPE_DIR}/generated/config-mpd.php" \
        > "${PROJECT_DIR}/config-mpd.php"
    echo "config-mpd.php generated."
elif [ -z "$DATABASE_ID" ]; then
    echo "MPD_DB unset — skipping config-mpd.php generation."
else
    echo "Moodle source not detected yet — skipping config-mpd.php generation."
fi

# --- Allocate (or reuse) FPM port (9100–9199 pool) ---
# A dedicated pool keeps FPM ports predictable and clear of anything else
# that binds inside the runtime (caddy on 80/443, sshd on 22). Historical
# note: the pool originally dodged the Selenium sidecar's ports (9000,
# 4444, 5900/7900, 9222) back when selenium shared the pod netns; selenium
# is its own container now, but the pool is a fine convention to keep.
FPM_POOL_START=9100
FPM_POOL_END=9199
EFFECTIVE_FILE="/srv/meta/${PROJECT_NAME}/effective.json"
FPM_PORT=""
if [ -f "$EFFECTIVE_FILE" ]; then
    FPM_PORT=$(jq -r '.phpFpmPort // empty' "$EFFECTIVE_FILE" 2>/dev/null || true)
fi
# Drop a previously-assigned port that falls outside the current pool (e.g. a
# legacy 9000 from before the pool moved off the Selenium clash) so it gets
# reallocated into the valid range below.
if [ -n "$FPM_PORT" ] && { [ "$FPM_PORT" -lt "$FPM_POOL_START" ] || [ "$FPM_PORT" -gt "$FPM_POOL_END" ]; }; then
    FPM_PORT=""
fi
if [ -z "$FPM_PORT" ]; then
    USED_PORTS=$(for f in /srv/meta/*/effective.json; do
        [ -f "$f" ] || continue
        jq -r '.phpFpmPort // empty' "$f" 2>/dev/null
    done | sort -un)
    for p in $(seq "$FPM_POOL_START" "$FPM_POOL_END"); do
        if ! echo "$USED_PORTS" | grep -qx "$p"; then
            FPM_PORT="$p"
            break
        fi
    done
    if [ -z "$FPM_PORT" ]; then
        echo "Error: FPM port pool exhausted (${FPM_POOL_START}-${FPM_POOL_END})" >&2
        exit 1
    fi
fi
FPM_SOCK="127.0.0.1:${FPM_PORT}"

# --- Document root: Moodle 5+ uses public/ subdirectory ---
if [ -f "${PROJECT_DIR}/public/version.php" ]; then
    DOCROOT="${PROJECT_DIR}/public"
else
    DOCROOT="${PROJECT_DIR}"
fi

# --- urls.json ---
URLS='[
  {
    "label": "main",
    "kind": "web",
    "url": "https://'"${PROJECT_NAME}"'.'"${MPD_ZONE}"'/",
    "backend": {
      "type": "php-fpm",
      "fastcgi": "'"${FPM_SOCK}"'",
      "root": "'"${DOCROOT}"'",
      "tryFiles": ["{path}", "{path}/index.php", "/r.php"]
    }
  }'
if [ "$BEHAT" = "1" ]; then
    URLS="${URLS}"',
  {
    "label": "behat",
    "kind": "behat",
    "url": "https://behat.'"${PROJECT_NAME}"'.'"${MPD_ZONE}"'/",
    "backend": {
      "type": "php-fpm",
      "fastcgi": "'"${FPM_SOCK}"'",
      "root": "'"${DOCROOT}"'",
      "tryFiles": ["{path}", "{path}/index.php", "/r.php"]
    }
  }'
fi

# Informational mail link (no backend — the frontdoor skips it, and mpd
# excludes kind:"mail" from certs/DNS): the shared mailpit inbox,
# pre-filtered to mail referencing this project's wwwroot, which Moodle
# embeds in every message. Clearing the search reveals the full shared
# inbox, making the scope visible in the address bar.
if _service_enabled mailpit; then
    URLS="${URLS}"',
  {
    "label": "mail",
    "kind": "mail",
    "url": "http://mailpit.svc.'"${MPD_ZONE}"':8025/?q='"${PROJECT_NAME}"'.'"${MPD_ZONE}"'"
  }'
fi
URLS="${URLS}"'
]'
echo "$URLS" > "/srv/meta/${PROJECT_NAME}/urls.json"

# --- effective.json — mpd reads dbTag/dbEngine to provision the container ---
cat > "${EFFECTIVE_FILE}" <<EOF
{
  "phpVersion": "${PHP_VER}",
  "phpFpmPort": ${FPM_PORT},
  "behat": ${BEHAT},
  "dbTag": "${DB_TAG}",
  "dbEngine": "${DB_ENGINE}",
  "dbVersion": "${DB_VERSION}",
  "databaseId": "${DATABASE_ID}"
}
EOF

if [ -n "$DATABASE_ID" ]; then
    echo "Done: '${PROJECT_NAME}' configured → ${DBTYPE} @ ${DATABASE_ID} (php ${PHP_VER}, behat=${BEHAT})"
else
    echo "Done: '${PROJECT_NAME}' configured → no DB (php ${PHP_VER}, behat=${BEHAT})"
fi
