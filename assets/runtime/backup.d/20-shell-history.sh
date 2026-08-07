#!/bin/bash
# Backup hook: shell history.
#
# Runs inside the runtime as the dev user; $1 is the backup directory.
set -euo pipefail

DEST="$1/shell"

if [ ! -f "$HOME/.bash_history" ]; then
    echo "shell-history: nothing to back up."
    exit 0
fi
mkdir -p "$DEST"
cp -a "$HOME/.bash_history" "$DEST/"
echo "shell-history: backed up."
