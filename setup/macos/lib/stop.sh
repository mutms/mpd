#!/bin/bash
# stop.sh — suspend all running mpd VMs (state preserved on disk; resumes instantly).
# Called by stop.command.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

found_running=0
while IFS=$'\t' read -r name state; do
    [ -z "$name" ] && continue
    if [ "$state" = "running" ]; then
        echo "Suspending ${name} ..."
        vm_suspend "$name"
        echo "  Suspended."
        found_running=1
    fi
done < <(get_mpd_vms)

if [ "$found_running" = 0 ]; then
    echo "No mpd VMs are running."
fi
