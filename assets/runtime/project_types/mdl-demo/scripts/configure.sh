#!/bin/bash
# configure.sh <project-name>
# Idempotent configure step for an mdl-demo project, run by `mpd start`.
# Publishes the front door only: console and site URLs reverse-proxied
# to VM ports 6381/6382, the contract with mdl-demo's Makefile. See
# docs/usage.md (mdl-demo). effective.json marks the project
# configured; its empty database fields mean no DB.
set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"
TYPE_DIR="/opt/mpd/assets/runtime/project_types/mdl-demo"
CONSOLE_PORT=6381
SITE_PORT=6382

if [ ! -d "$PROJECT_DIR" ]; then
    echo "Error: ${PROJECT_DIR} does not exist — run mpd init ${PROJECT_NAME} first" >&2
    exit 1
fi

# Provides MPD_ZONE (and fails loudly without it).
# shellcheck source=/dev/null
source /opt/mpd/assets/runtime/lib/source-mpd-env.sh

# The upstream is the VM's bridge address; 127.0.0.1 would be the
# runtime itself.
GATEWAY=$(jq -r '.gateway // empty' /srv/meta/vm.json 2>/dev/null || true)
if [ -z "$GATEWAY" ]; then
    echo "Error: VM gateway unavailable (/srv/meta/vm.json) — run 'mpd --start' on the VM to republish it" >&2
    exit 1
fi

# Re-apply template/ so older projects pick up new template files.
# shellcheck source=/dev/null
. /opt/mpd/assets/runtime/lib/project-template.sh
apply_project_template "$PROJECT_NAME" "$TYPE_DIR"

# /srv/meta is dev-owned, so a plain mkdir works.
mkdir -p "/srv/meta/${PROJECT_NAME}"

cat > "/srv/meta/${PROJECT_NAME}/urls.json" <<EOF
[
  {
    "label": "console",
    "kind": "web",
    "url": "https://${PROJECT_NAME}.${MPD_ZONE}/",
    "backend": {
      "type": "reverse-proxy",
      "upstream": "http://${GATEWAY}:${CONSOLE_PORT}"
    }
  },
  {
    "label": "site",
    "kind": "web",
    "url": "https://site.${PROJECT_NAME}.${MPD_ZONE}/",
    "backend": {
      "type": "reverse-proxy",
      "upstream": "http://${GATEWAY}:${SITE_PORT}"
    }
  }
]
EOF

# Empty dbTag keeps mpd from provisioning a database. The ports are
# informational; project-setup.sh prints them.
cat > "/srv/meta/${PROJECT_NAME}/effective.json" <<EOF
{
  "dbTag": "",
  "dbEngine": "",
  "dbVersion": "",
  "databaseId": "",
  "consolePort": ${CONSOLE_PORT},
  "sitePort": ${SITE_PORT}
}
EOF

echo "Done: '${PROJECT_NAME}' configured (mdl-demo — https://${PROJECT_NAME}.${MPD_ZONE}/ → VM :${CONSOLE_PORT}, https://site.${PROJECT_NAME}.${MPD_ZONE}/ → VM :${SITE_PORT})."
