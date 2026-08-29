#!/bin/bash
# project-create.sh <project-name>
# Run by `mpd init <project>`, after any git clone and before the
# project is registered. apply_project_template seeds template/ files
# (never overwriting) and maintains the git excludes.
set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"
TYPE_DIR="/opt/mpd/assets/runtime/project_types/astro"

if [ ! -d "$PROJECT_DIR" ]; then
    echo "Error: ${PROJECT_DIR} does not exist." >&2
    exit 1
fi

# shellcheck source=/dev/null
. /opt/mpd/assets/runtime/lib/project-template.sh
apply_project_template "$PROJECT_NAME" "$TYPE_DIR"

echo "Project '${PROJECT_NAME}' scaffolded — next: mpd start ${PROJECT_NAME}"
