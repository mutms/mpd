#!/bin/bash
# project-delete.sh <project>
# Bare project type — nothing to tear down.
set -euo pipefail

PROJECT_NAME="$1"
echo "Bare project '$PROJECT_NAME' cleanup complete (nothing to remove)."
