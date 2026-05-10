#!/bin/bash
# project-setup.sh <project>
# Bare project type — no Apache, no systemd, no config generation.
# Just ensures the project directory exists.
set -euo pipefail

PROJECT_NAME="$1"
mkdir -p "/srv/projects/$PROJECT_NAME"
echo "Bare project '$PROJECT_NAME' registered. No web server configured — manage your own."
