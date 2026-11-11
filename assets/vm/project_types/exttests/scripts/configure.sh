#!/bin/bash
# configure.sh <project-name>
# Idempotent configure step for the Moodle external test files, run by
# `mpd start`: re-applies template/, allocates the FPM port and writes
# /srv/meta/<project>/{urls.json,effective.json}.
set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"
TYPE_DIR="/opt/mpd/assets/vm/project_types/exttests"
EFFECTIVE_FILE="/srv/meta/${PROJECT_NAME}/effective.json"

if [ ! -d "$PROJECT_DIR" ]; then
    echo "Error: ${PROJECT_DIR} does not exist — run mpd init ${PROJECT_NAME} --type=exttests first" >&2
    exit 1
fi

# shellcheck source=/dev/null
. /opt/mpd/assets/vm/lib/project-template.sh
apply_project_template "$PROJECT_NAME" "$TYPE_DIR"

mkdir -p "/srv/meta/${PROJECT_NAME}"

# shellcheck source=/dev/null
source /opt/mpd/assets/vm/lib/source-mpd-env.sh
# shellcheck source=/dev/null
. /opt/mpd/assets/vm/lib/php-configure.sh
PHP_VER="${MPD_PHP_VERSION:-$MPD_PHP_FALLBACK_VERSION}"
/opt/mpd/assets/vm/bin/php-install "$PHP_VER"

# FPM ports share the 9100-9199 pool with Moodle projects.
FPM_POOL_START=9100
FPM_POOL_END=9199
FPM_PORT=""
if [ -f "$EFFECTIVE_FILE" ]; then
    FPM_PORT=$(jq -r '.phpFpmPort // empty' "$EFFECTIVE_FILE" 2>/dev/null || true)
fi
if [ -n "$FPM_PORT" ] && { [ "$FPM_PORT" -lt "$FPM_POOL_START" ] || [ "$FPM_PORT" -gt "$FPM_POOL_END" ]; }; then
    FPM_PORT=""
fi
if [ -z "$FPM_PORT" ]; then
    USED_PORTS=$(for f in /srv/meta/*/effective.json; do
        [ -f "$f" ] || continue
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

# The plain http URL must stay: Moodle's tests check HTTP/1.1 status
# lines, and HTTPS here speaks HTTP/2. No catch-all script in tryFiles,
# so a missing file answers 404.
BACKEND='{
      "type": "php-fpm",
      "fastcgi": "127.0.0.1:'"${FPM_PORT}"'",
      "root": "'"${PROJECT_DIR}"'",
      "tryFiles": ["{path}", "{path}/index.php"]
    }'
cat > "/srv/meta/${PROJECT_NAME}/urls.json" <<JSON
[
  {
    "label": "main",
    "kind": "web",
    "url": "https://${PROJECT_NAME}.${MPD_ZONE}/",
    "backend": ${BACKEND}
  },
  {
    "label": "http",
    "kind": "web",
    "url": "http://${PROJECT_NAME}.${MPD_ZONE}/",
    "backend": ${BACKEND}
  }
]
JSON

cat > "$EFFECTIVE_FILE" <<JSON
{
  "phpVersion": "${PHP_VER}",
  "phpFpmPort": ${FPM_PORT},
  "dbTag": "",
  "dbEngine": "",
  "dbVersion": "",
  "databaseId": ""
}
JSON

echo "Done: '${PROJECT_NAME}' configured (php ${PHP_VER}, FPM 127.0.0.1:${FPM_PORT})."
