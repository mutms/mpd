#!/bin/bash
# configure.sh <project-name>
# Idempotent project repair/configuration for Moodle. Run by Swift's
# `mpd configure <project>` after Swift has applied any KEY=VALUE mutations
# to /srv/projects/<project>/mpd.env.
#
# Responsibilities:
#   - Source layered mpd.env (/var/lib/mpd/env/mpd-vm.env then project mpd.env)
#   - Resolve MPD_DB to dbTag/dbEngine/databaseId for downstream use
#   - Fix ownership of /srv/projects/<project>
#   - Ensure dataroot dirs exist with expected perms
#   - Regenerate config-mpd.php (when MPD_DB is set + Moodle source detected)
#   - Create config.php if missing
#   - Allocate FPM port
#   - Emit /srv/meta/<project>/urls.json + effective.json
#
# Swift reads effective.json's dbTag (and re-sanitises) to provision the DB
# container. dbTag empty (or missing) means "no DB for this project".
set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"
DATAROOT="/srv/data/${PROJECT_NAME}/dataroot"
BEHATDATAROOT="/srv/data/${PROJECT_NAME}/dataroot_behat"
PHPUNITDATAROOT="/srv/data/${PROJECT_NAME}/dataroot_phpunit"

if [ ! -d "$PROJECT_DIR" ]; then
    echo "Error: ${PROJECT_DIR} does not exist — run mpd ${PROJECT_NAME} create first" >&2
    exit 1
fi

# /srv/meta/<project>/ holds urls.json + effective.json (read by Swift, the
# caddy sidecar, and the FPM provisioner) plus cert.pem/key.pem/project.json
# that Swift writes via volumeToolRun (--user <uid>:<uid>). /srv/meta is
# dev-owned (mode 0775) by fileaccess provisioning, so plain mkdir works.
mkdir -p "/srv/meta/${PROJECT_NAME}"

# Layered config: /var/lib/mpd/env/mpd-vm.env (bind-mounted RO), then per-project
# /srv/projects/<n>/mpd.env. Project wins; explicit empty in project blocks
# user-level fall-through; absent key in project falls through.
# shellcheck source=/dev/null
source /opt/mpd/assets/runtime-base/lib/source-mpd-env.sh

# --- Resolve effective settings ---
PHP_VER="${MPD_PHP_VERSION}"
BEHAT="${MPD_PHP_MOODLE_BEHAT}"

# MPD_DB (docker tag form): "postgres", "postgres:17", "postgres:latest", or
# "" (empty = no DB). Bare engine expands to engine:latest. Swift re-validates
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
# dev-owned (set by fileaccess provisioning), so plain mkdir/chmod work.
for DIR in "$DATAROOT" "$BEHATDATAROOT" "$PHPUNITDATAROOT"; do
    mkdir -p "$DIR"
    chmod 02777 "$DIR"
done

touch "${DATAROOT}/php_error.log"
chmod 0666 "${DATAROOT}/php_error.log"

# --- Generate config files (only when Moodle source + DB are both present) ---
if [ -n "$DATABASE_ID" ] && \
   { [ -f "${PROJECT_DIR}/version.php" ] || [ -f "${PROJECT_DIR}/public/version.php" ]; }; then
    # Compute the public tunnel host when cftunnel is enabled for this
    # project AND a public domain is set in /var/lib/mpd/env/mpd-vm.env. Empty
    # otherwise — the baked-in detection block then does nothing.
    CFTUNNEL_HOST=""
    if [ "${MPD_PHP_MOODLE_CFTUNNEL:-}" = "1" ] && [ -n "${MPD_UTIL_CFTUNNEL_DOMAIN:-}" ]; then
        case "$MPD_UTIL_CFTUNNEL_DOMAIN" in
            .*) CFTUNNEL_HOST="${PROJECT_NAME}${MPD_UTIL_CFTUNNEL_DOMAIN}" ;;
            *)  CFTUNNEL_HOST="${PROJECT_NAME}.${MPD_UTIL_CFTUNNEL_DOMAIN}" ;;
        esac
    fi
    sed \
        -e "s|%%PROJECT%%|${PROJECT_NAME}|g" \
        -e "s|%%DBTYPE%%|${DBTYPE}|g" \
        -e "s|%%DBHOST%%|${DATABASE_ID}.db.mpd.test|g" \
        -e "s|%%CFTUNNEL_HOST%%|${CFTUNNEL_HOST}|g" \
        /opt/mpd/assets/runtimes/php/project_types/moodle/templates/config-mpd-generated.php \
        > "${PROJECT_DIR}/config-mpd.php"
    echo "config-mpd.php generated."

    if [ ! -f "${PROJECT_DIR}/config.php" ]; then
        cp /opt/mpd/assets/runtimes/php/project_types/moodle/templates/config.php "${PROJECT_DIR}/config.php"
        echo "config.php created."
    else
        echo "config.php already exists — not overwritten."
    fi
elif [ -z "$DATABASE_ID" ]; then
    echo "MPD_DB unset — skipping config.php / config-mpd.php generation."
else
    echo "Moodle source not detected yet — skipping config.php / config-mpd.php generation."
fi

# --- Allocate (or reuse) FPM port (9000–9099 pool) ---
EFFECTIVE_FILE="/srv/meta/${PROJECT_NAME}/effective.json"
FPM_PORT=""
if [ -f "$EFFECTIVE_FILE" ]; then
    FPM_PORT=$(jq -r '.phpFpmPort // empty' "$EFFECTIVE_FILE" 2>/dev/null || true)
fi
if [ -z "$FPM_PORT" ]; then
    USED_PORTS=$(for f in /srv/meta/*/effective.json; do
        [ -f "$f" ] || continue
        jq -r '.phpFpmPort // empty' "$f" 2>/dev/null
    done | sort -un)
    for p in $(seq 9000 9099); do
        if ! echo "$USED_PORTS" | grep -qx "$p"; then
            FPM_PORT="$p"
            break
        fi
    done
    if [ -z "$FPM_PORT" ]; then
        echo "Error: FPM port pool exhausted (9000-9099)" >&2
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
    "url": "https://'"${PROJECT_NAME}"'.mpd.test/",
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
    "url": "https://behat.'"${PROJECT_NAME}"'.mpd.test/",
    "backend": {
      "type": "php-fpm",
      "fastcgi": "'"${FPM_SOCK}"'",
      "root": "'"${DOCROOT}"'",
      "tryFiles": ["{path}", "{path}/index.php", "/r.php"]
    }
  }'
fi

# Cloudflare Tunnel public hostname (when enabled). Same FPM backend
# as main, so gen-caddyfile.sh's by-backend grouping merges them into
# one Caddy vhost — the *.mpd.test cert presented at TLS handshake
# (SNI = <project>.mpd.test from cloudflared's service URL) covers
# the connection; Caddy routes by Host once TLS is up.
# `kind: "tunnel"` so the portal can render a distinct badge later.
CFTUNNEL_PUBLIC_HOST=""
if [ "${MPD_PHP_MOODLE_CFTUNNEL:-}" = "1" ] && [ -n "${MPD_UTIL_CFTUNNEL_DOMAIN:-}" ]; then
    case "$MPD_UTIL_CFTUNNEL_DOMAIN" in
        .*) CFTUNNEL_PUBLIC_HOST="${PROJECT_NAME}${MPD_UTIL_CFTUNNEL_DOMAIN}" ;;
        *)  CFTUNNEL_PUBLIC_HOST="${PROJECT_NAME}.${MPD_UTIL_CFTUNNEL_DOMAIN}" ;;
    esac
    URLS="${URLS}"',
  {
    "label": "tunnel",
    "kind": "tunnel",
    "url": "https://'"${CFTUNNEL_PUBLIC_HOST}"'/",
    "backend": {
      "type": "php-fpm",
      "fastcgi": "'"${FPM_SOCK}"'",
      "root": "'"${DOCROOT}"'",
      "tryFiles": ["{path}", "{path}/index.php", "/r.php"]
    }
  }'
fi
# Per-project mail URL is a 302 shortcut to the runtime-level canonical
# mailpit URL (mail.<runtime>.mpd.test/) with a search filter. The actual
# mailbox is shared across all projects on this runtime — pretending each
# project has its own mailbox via reverse-proxy was a UI lie. The query
# string `q=<project>.mpd.test` filters to mail referencing this project's
# wwwroot, which Moodle embeds in every email. Cleared search reveals the
# full inbox, making the shared scope visible in the address bar.
RUNTIME_NAME=$(cat /etc/mpd/runtime)
URLS="${URLS}"',
  {
    "label": "mail",
    "kind": "mail",
    "url": "https://mail.'"${PROJECT_NAME}"'.mpd.test/",
    "backend": {
      "type": "redirect",
      "target": "https://mail.'"${RUNTIME_NAME}"'.mpd.test/?q='"${PROJECT_NAME}"'.mpd.test"
    }
  }'
URLS="${URLS}"'
]'
echo "$URLS" > "/srv/meta/${PROJECT_NAME}/urls.json"

# --- effective.json — Swift reads dbTag/dbEngine to provision the container ---
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
