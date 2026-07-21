#!/bin/bash
set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"

# Per-project mpd.env was seeded by project-create.sh at create time;
# bare has no resolved knobs to emit. mpd reads dbTag from effective.json
# (empty → no DB), so produce one even with nothing else inside.
mkdir -p "$PROJECT_DIR"
mkdir -p "/srv/meta/${PROJECT_NAME}"
cat > "/srv/meta/${PROJECT_NAME}/effective.json" <<EOF
{
  "dbTag": "",
  "dbEngine": "",
  "dbVersion": "",
  "databaseId": ""
}
EOF
cat > "/srv/meta/${PROJECT_NAME}/urls.json" <<EOF
[]
EOF

echo "Done: bare project '${PROJECT_NAME}' configured."
