#!/bin/bash
# configure.sh <project-name>
# Idempotent configure step for an mdl-demo project, run by `mpd start`.
#
# An mdl-demo project is the source tree of the mdl-demo tool itself. mpd
# does not build or run its demo container — the developer does that by
# hand (see project-setup.sh). So configure has almost nothing to do: it
# re-applies the template and writes the two meta files every project type
# owes mpd.
#
#   urls.json       empty — mpd publishes no vhost, certificate or DNS.
#   effective.json  empty database fields — this type uses no database.
#                   Its presence is what marks the project "configured".
set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"
TYPE_DIR="/opt/mpd/assets/runtime/project_types/mdl-demo"

if [ ! -d "$PROJECT_DIR" ]; then
    echo "Error: ${PROJECT_DIR} does not exist — run mpd init ${PROJECT_NAME} first" >&2
    exit 1
fi

# Re-apply template/ so a project created before a template file existed
# picks it up here. mpd.env is never overwritten once present.
# shellcheck source=/dev/null
. /opt/mpd/assets/runtime/lib/project-template.sh
apply_project_template "$PROJECT_NAME" "$TYPE_DIR"

# /srv/meta is dev-owned, so a plain mkdir works.
mkdir -p "/srv/meta/${PROJECT_NAME}"

# No web endpoint: the developer builds and runs the container by hand,
# with its own host ports. mpd publishes no vhost, certificate or DNS.
echo "[]" > "/srv/meta/${PROJECT_NAME}/urls.json"

# No database: this type uses none. An empty dbTag keeps mpd from
# provisioning one. The keys match what mpd reads from effective.json.
cat > "/srv/meta/${PROJECT_NAME}/effective.json" <<EOF
{
  "dbTag": "",
  "dbEngine": "",
  "dbVersion": "",
  "databaseId": ""
}
EOF

echo "Done: '${PROJECT_NAME}' configured (mdl-demo — no database, no web endpoint)."
