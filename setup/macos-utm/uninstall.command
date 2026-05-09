#!/bin/bash
# uninstall.command — delete all mpd VMs and remove host networking.
# Double-clickable in Finder; macOS opens Terminal.app automatically.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status=0
bash "${SCRIPT_DIR}/lib/uninstall.sh" "$@" || status=$?
echo
read -r -p "Press Enter to close..." _ || true
exit "$status"
