#!/bin/bash
# project-create.sh <project-name>
# Run by `mpd create <project>` inside the runtime container, AFTER any
# git clone and BEFORE the project is registered as ready.
#
# Responsibilities:
#   - Seed /srv/projects/<project>/mpd.env from this type's mpd-template.env
#     (only if mpd.env is absent — pre-existing user-supplied mpd.env is sacred).
#   - Add /mpd.env to .git/info/exclude so it isn't committed.
#
# Does NOT:
#   - Create databases (that's `mpd configure <project>`).
#   - Generate config.php / config-mpd.php (that's `mpd configure <project>`
#     via scripts/configure.sh).
#   - Run any project-type-specific setup that needs a runtime context.
set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"
PROJECT_ENV="${PROJECT_DIR}/mpd.env"
TEMPLATE_ENV="/opt/mpd/assets/runtimes/php/project_types/moodle/mpd-template.env"

if [ ! -d "$PROJECT_DIR" ]; then
    echo "Error: ${PROJECT_DIR} does not exist." >&2
    exit 1
fi

# Seed mpd.env from template (sacred if pre-existing).
if [ ! -f "$PROJECT_ENV" ]; then
    if [ ! -f "$TEMPLATE_ENV" ]; then
        echo "Error: template ${TEMPLATE_ENV} not found." >&2
        exit 1
    fi
    install -m 0644 "$TEMPLATE_ENV" "$PROJECT_ENV"
    echo "Seeded ${PROJECT_ENV} from template."
else
    echo "Existing ${PROJECT_ENV} preserved."
fi

# Exclude /mpd.env from git (per-clone, not committed).
if [ -d "${PROJECT_DIR}/.git" ]; then
    EXCLUDE="${PROJECT_DIR}/.git/info/exclude"
    mkdir -p "$(dirname "$EXCLUDE")"
    if ! grep -qxF "/mpd.env" "$EXCLUDE" 2>/dev/null; then
        echo "/mpd.env" >> "$EXCLUDE"
    fi
fi

echo "Project '${PROJECT_NAME}' scaffolded — next: mpd configure ${PROJECT_NAME}"
