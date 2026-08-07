#!/bin/bash
# Restore hook: shell history. Inverse of backup.d/20-shell-history.sh;
# $1 is the backup directory to restore from.
set -euo pipefail

SRC="$1/shell"

if [ ! -f "$SRC/.bash_history" ]; then
    echo "shell-history: nothing to restore."
    exit 0
fi
cp -a "$SRC/.bash_history" "$HOME/"
echo "shell-history: restored."
