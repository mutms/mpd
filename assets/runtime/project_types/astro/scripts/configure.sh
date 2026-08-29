#!/bin/bash
# configure.sh <project-name>
# Idempotent configure step for an Astro project, run by `mpd start`:
# re-applies template/, ensures dependencies, resolves the dev-server
# port, and writes /srv/meta/<project>/{urls.json,effective.json}.
set -euo pipefail

# shellcheck source=/dev/null
source /opt/mpd/assets/runtime/lib/nvm-env.sh

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"
TYPE_DIR="/opt/mpd/assets/runtime/project_types/astro"

if [ ! -d "$PROJECT_DIR" ]; then
    echo "Error: ${PROJECT_DIR} does not exist — run mpd ${PROJECT_NAME} create first" >&2
    exit 1
fi

# Re-apply template/ first so mpd.env exists for source-mpd-env.sh
# below and older projects pick up new template files.
# shellcheck source=/dev/null
. /opt/mpd/assets/runtime/lib/project-template.sh
apply_project_template "$PROJECT_NAME" "$TYPE_DIR"

if [ ! -f "${PROJECT_DIR}/package.json" ]; then
    echo "Error: ${PROJECT_DIR}/package.json not found — is this an Astro/Node project?" >&2
    exit 1
fi

# /srv/meta is dev-owned, so plain mkdir works.
mkdir -p "/srv/meta/${PROJECT_NAME}"

# shellcheck source=/dev/null
source /opt/mpd/assets/runtime/lib/source-mpd-env.sh

cd "${PROJECT_DIR}"

if [ -f ".nvmrc" ]; then
    nvm install
fi

if [ ! -d "${PROJECT_DIR}/node_modules" ]; then
    echo "node_modules missing — running npm install..."
    npm install
else
    echo "node_modules already present — skipping npm install."
fi

# The port comes from astro.config.mjs only (default 4321): the server
# reads that file itself, so a separate mpd-side setting could disagree
# and surface as a 502. Two astro projects in one runtime need distinct
# server.port values.
PORT="4321"
if [ -f "${PROJECT_DIR}/astro.config.mjs" ]; then
    DETECTED=$(grep -oE 'port\s*:\s*[0-9]+' "${PROJECT_DIR}/astro.config.mjs" 2>/dev/null \
        | grep -oE '[0-9]+' || true)
    [ -n "$DETECTED" ] && PORT="$DETECTED"
fi

# caddy reverse-proxies https://<project>.<zone> to the dev server.
# The upstream must stay the name "localhost", not an IP — see
# docs/usage.md (Astro).
cat > "/srv/meta/${PROJECT_NAME}/urls.json" <<EOF
[
  {
    "label": "main",
    "kind": "web",
    "url": "https://${PROJECT_NAME}.${MPD_ZONE}/",
    "backend": {
      "type": "reverse-proxy",
      "upstream": "http://localhost:${PORT}"
    }
  }
]
EOF

# effective.json marks the project configured; empty dbTag = no DB.
cat > "/srv/meta/${PROJECT_NAME}/effective.json" <<EOF
{
  "port": ${PORT},
  "dbTag": "",
  "dbEngine": "",
  "dbVersion": "",
  "databaseId": ""
}
EOF

echo "Done: '${PROJECT_NAME}' configured (port ${PORT})."
