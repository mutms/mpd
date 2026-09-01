#!/bin/bash
# configure.sh <project-name>
# Idempotent configure step for a Moodle project, run by `mpd start`
# after mpd applies KEY=VALUE mutations to mpd.env. Re-applies
# template/, resolves the layered config, renders config-mpd.php,
# allocates the FPM port, and writes
# /srv/meta/<project>/{urls.json,effective.json}. mpd reads
# effective.json's dbTag to provision the DB; empty means no DB.
set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"
DATAROOT="/srv/data/${PROJECT_NAME}/dataroot"
BEHATDATAROOT="/srv/data/${PROJECT_NAME}/dataroot_behat"
BEHATFAILDUMP="/srv/data/${PROJECT_NAME}/behat_faildump"
PHPUNITDATAROOT="/srv/data/${PROJECT_NAME}/dataroot_phpunit"
TYPE_DIR="/opt/mpd/assets/vm/project_types/moodle"

if [ ! -d "$PROJECT_DIR" ]; then
    echo "Error: ${PROJECT_DIR} does not exist — run mpd ${PROJECT_NAME} create first" >&2
    exit 1
fi

# Re-apply template/ first so mpd.env exists for source-mpd-env.sh
# below and older projects pick up new template files.
# shellcheck source=/dev/null
. /opt/mpd/assets/vm/lib/project-template.sh
apply_project_template "$PROJECT_NAME" "$TYPE_DIR"

# /srv/meta is dev-owned, so plain mkdir works.
mkdir -p "/srv/meta/${PROJECT_NAME}"

# shellcheck source=/dev/null
source /opt/mpd/assets/vm/lib/source-mpd-env.sh

# Explicit MPD_PHP_VERSION wins; php-configure.sh holds the fallback.
# shellcheck source=/dev/null
. /opt/mpd/assets/vm/lib/php-configure.sh
PHP_VER="${MPD_PHP_VERSION:-$MPD_PHP_FALLBACK_VERSION}"
BEHAT="${MPD_MOODLE_BEHAT}"

# php-install no-ops when the version is present and installs a legacy
# one on demand. Done at configure time so CLI tools run the project's
# real version, not the php wrapper's fallback.
/opt/mpd/assets/vm/bin/php-install "$PHP_VER"

# MPD_DB is a docker tag: "postgres", "postgres:17", or "" for no DB.
# A bare engine expands to engine:latest; mpd re-validates on read.
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

# The script runs as the dev user and /srv/data is dev-owned, so
# plain mkdir/chmod work.
for DIR in "$DATAROOT" "$BEHATDATAROOT" "$BEHATFAILDUMP" "$PHPUNITDATAROOT"; do
    mkdir -p "$DIR"
    chmod 02777 "$DIR"
done

touch "${DATAROOT}/php_error.log"
chmod 0666 "${DATAROOT}/php_error.log"

# MPD_REQUIRE_SERVICES (comma-separated, from mpd.env) names the
# service containers this project needs. mpd reads it back from
# effective.json to auto-start them. Keying mail config off the
# project's own declaration keeps noemailever the default.
REQUIRE_SERVICES="${MPD_REQUIRE_SERVICES:-}"
# Behat needs selenium; adding it here lets mpd auto-enable the
# container without special-casing behat.
if [ "$BEHAT" = "1" ]; then
    REQUIRE_SERVICES="${REQUIRE_SERVICES:+${REQUIRE_SERVICES},}selenium"
fi
_service_required() {
    case ",${REQUIRE_SERVICES// /}," in
        *",$1,"*) return 0 ;;
        *) return 1 ;;
    esac
}

# A project that requires mailpit sends into it; otherwise noemailever
# blocks all outgoing mail. One line either way, so the sed below
# stays single-line.
if _service_required mailpit; then
    MAIL_CONFIG="\$CFG->smtphosts = 'mailpit.svc.${MPD_ZONE}:1025';"
else
    MAIL_CONFIG="\$CFG->noemailever = true; // mailpit not in MPD_REQUIRE_SERVICES"
fi

# Render config-mpd.php when Moodle source and a DB are both present.
# config.php is static, seeded from template/ and left alone.
if [ -n "$DATABASE_ID" ] && \
   { [ -f "${PROJECT_DIR}/version.php" ] || [ -f "${PROJECT_DIR}/public/version.php" ]; }; then
    sed \
        -e "s|%%PROJECT%%|${PROJECT_NAME}|g" \
        -e "s|%%DBTYPE%%|${DBTYPE}|g" \
        -e "s|%%DBHOST%%|${DATABASE_ID}.db.${MPD_ZONE}|g" \
        -e "s|%%ZONE%%|${MPD_ZONE}|g" \
        -e "s|%%MAIL_CONFIG%%|${MAIL_CONFIG}|" \
        -e "s|%%SELENIUM_WD_HOST%%|http://selenium.svc.${MPD_ZONE}:4444/wd/hub|" \
        "${TYPE_DIR}/generated/config-mpd.php" \
        > "${PROJECT_DIR}/config-mpd.php"
    echo "config-mpd.php generated."
elif [ -z "$DATABASE_ID" ]; then
    echo "MPD_DB unset — skipping config-mpd.php generation."
else
    echo "Moodle source not detected yet — skipping config-mpd.php generation."
fi

# FPM ports come from a dedicated 9100-9199 pool, clear of anything
# else that binds on the VM.
FPM_POOL_START=9100
FPM_POOL_END=9199
EFFECTIVE_FILE="/srv/meta/${PROJECT_NAME}/effective.json"
FPM_PORT=""
if [ -f "$EFFECTIVE_FILE" ]; then
    FPM_PORT=$(jq -r '.phpFpmPort // empty' "$EFFECTIVE_FILE" 2>/dev/null || true)
fi
# A recorded port outside the current pool (from an older mpd) is
# dropped and reallocated below.
if [ -n "$FPM_PORT" ] && { [ "$FPM_PORT" -lt "$FPM_POOL_START" ] || [ "$FPM_PORT" -gt "$FPM_POOL_END" ]; }; then
    FPM_PORT=""
fi
if [ -z "$FPM_PORT" ]; then
    USED_PORTS=$(for f in /srv/meta/*/effective.json; do
        [ -f "$f" ] || continue
        # || true: one malformed effective.json must not abort the scan
        # (pipefail would propagate jq's exit).
        jq -r '.phpFpmPort // empty' "$f" 2>/dev/null || true
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

# Moodle 5+ serves from public/.
if [ -f "${PROJECT_DIR}/public/version.php" ]; then
    DOCROOT="${PROJECT_DIR}/public"
else
    DOCROOT="${PROJECT_DIR}"
fi

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

# Informational mail link: no backend, so the frontdoor skips it and
# mpd issues no cert or DNS for it. The query pre-filters the shared
# mailpit inbox to mail referencing this project's wwwroot.
if _service_required mailpit; then
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

# requireServices as a JSON array. --arg + -n turns empty input into
# []; piping into `jq -R` would emit nothing and break the JSON.
REQUIRE_JSON=$(jq -cn --arg s "${REQUIRE_SERVICES// /}" '$s | split(",") | map(select(length > 0))')

# mpd reads dbTag/dbEngine from effective.json to provision the container.
cat > "${EFFECTIVE_FILE}" <<EOF
{
  "phpVersion": "${PHP_VER}",
  "phpFpmPort": ${FPM_PORT},
  "behat": ${BEHAT},
  "requireServices": ${REQUIRE_JSON},
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
