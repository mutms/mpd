#!/bin/bash
# setup.command — create a new mpd VM or switch the active VM.
# Double-clickable in Finder; macOS opens Terminal.app automatically.
#
# Implementation lives in lib/setup.sh — no need to open this file.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status=0
bash "${SCRIPT_DIR}/lib/setup.sh" "$@" || status=$?
echo
read -r -p "Press Enter to close..." _ || true
exit "$status"
