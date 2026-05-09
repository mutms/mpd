#!/bin/bash
# start.command — start the current mpd VM (no prompts).
# Double-clickable in Finder; macOS opens Terminal.app automatically.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status=0
bash "${SCRIPT_DIR}/lib/start.sh" "$@" || status=$?
echo
read -r -p "Press Enter to close..." _ || true
exit "$status"
