#!/bin/bash
# project-create.sh <project-name>
# Run by `mpd init <project> --type=exttests`, on a moodle-exttests
# checkout of any branch. Seeds template/ files.
set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"
TYPE_DIR="/opt/mpd/assets/vm/project_types/exttests"
REPO="https://github.com/moodlehq/moodle-exttests.git"

if [ ! -d "$PROJECT_DIR" ]; then
    echo "Error: ${PROJECT_DIR} does not exist." >&2
    exit 1
fi

if [ ! -f "${PROJECT_DIR}/downloadtests.md5" ]; then
    echo "Error: ${PROJECT_DIR} is not a moodle-exttests checkout. Clone it first:" >&2
    echo "  git clone ${REPO} ${PROJECT_DIR}" >&2
    exit 1
fi

# shellcheck source=/dev/null
. /opt/mpd/assets/vm/lib/project-template.sh
apply_project_template "$PROJECT_NAME" "$TYPE_DIR"

echo "Project '${PROJECT_NAME}' scaffolded — next: mpd start ${PROJECT_NAME}"
