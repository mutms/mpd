#!/bin/bash
# project-create.sh <project-name>
# Run by `mpd init <project>` inside the runtime container, AFTER any
# git clone and BEFORE the project is registered as ready.
#
# Responsibilities:
#   - Seed /srv/projects/<project>/ from this type's template/ directory
#     (mpd.env). Existing files are never overwritten — a user-supplied
#     mpd.env is sacred.
#   - Add every template/ path to .git/info/exclude.
# Both are apply_project_template's job; `mpd start` calls it again so a
# file added to template/ later reaches projects that already exist.
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
