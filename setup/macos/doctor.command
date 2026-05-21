#!/bin/bash
# doctor.command — verify (and re-apply) host networking for the active
# mpd VM. Double-clickable in Finder; macOS opens Terminal.app
# automatically.
#
# Implementation lives in lib/doctor.sh — no need to open this file.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status=0
bash "${SCRIPT_DIR}/lib/doctor.sh" "$@" || status=$?
echo
read -r -p "Press Enter to close..." _ || true
exit "$status"
