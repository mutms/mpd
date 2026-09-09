#!/bin/bash
# configure.sh <project-name>
# Idempotent configure step for a static site, run by `mpd start`:
# re-applies template/, works out which directory to serve, and writes
# /srv/meta/<project>/{urls.json,effective.json}.
#
# Nothing is built and nothing is started: caddy serves the files where
# they are, which is the whole point of this project type.
set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"
TYPE_DIR="/opt/mpd/assets/vm/project_types/html"

if [ ! -d "$PROJECT_DIR" ]; then
    echo "Error: ${PROJECT_DIR} does not exist — run mpd init ${PROJECT_NAME} --type=html first" >&2
    exit 1
fi

# Re-apply template/ first so mpd.env exists for source-mpd-env.sh below
# and older projects pick up new template files.
# shellcheck source=/dev/null
. /opt/mpd/assets/vm/lib/project-template.sh
apply_project_template "$PROJECT_NAME" "$TYPE_DIR"

# /srv/meta is dev-owned, so plain mkdir works.
mkdir -p "/srv/meta/${PROJECT_NAME}"

# Exports MPD_ZONE and any MPD_* set for this project.
# shellcheck source=/dev/null
source /opt/mpd/assets/vm/lib/source-mpd-env.sh

# MPD_DOCROOT names the directory to publish, relative to the project.
# Empty means the project itself. A leading slash, or a path climbing out
# with "..", is refused rather than silently serving somewhere else.
DOCROOT="${MPD_DOCROOT:-}"
case "$DOCROOT" in
    /* | *..*)
        echo "Error: MPD_DOCROOT must be a path inside the project (got '${DOCROOT}')." >&2
        exit 1
        ;;
esac

ROOT="${PROJECT_DIR}"
if [ -n "$DOCROOT" ]; then
    ROOT="${PROJECT_DIR}/${DOCROOT%/}"
fi

if [ ! -d "$ROOT" ]; then
    echo "Error: ${ROOT} does not exist. Set MPD_DOCROOT in ${PROJECT_DIR}/mpd.env." >&2
    exit 1
fi

if [ ! -f "${ROOT}/index.html" ]; then
    echo "Warning: no index.html in ${ROOT} — the site will answer 404 at its root."
fi

cat > "/srv/meta/${PROJECT_NAME}/urls.json" <<EOF
[
  {
    "label": "main",
    "kind": "web",
    "url": "https://${PROJECT_NAME}.${MPD_ZONE}/",
    "backend": {
      "type": "static",
      "root": "${ROOT}"
    }
  }
]
EOF

# effective.json marks the project configured; empty dbTag = no database.
cat > "/srv/meta/${PROJECT_NAME}/effective.json" <<EOF
{
  "docroot": "${ROOT}",
  "dbTag": "",
  "dbEngine": "",
  "dbVersion": "",
  "databaseId": ""
}
EOF

echo "Done: '${PROJECT_NAME}' configured (serving ${ROOT})."
