#!/bin/bash
# Restore hook: the developer's home directory. Inverse of
# backup.d/10-home.sh; $1 is the backup directory. No-op when the backup
# carries no home archive. Binaries were excluded from the backup and are
# not restored.
set -euo pipefail

ARCHIVE="$1/home.tar.gz"
if [ ! -f "$ARCHIVE" ]; then
    echo "home: nothing to restore."
    exit 0
fi

tar -xzf "$ARCHIVE" -C "$HOME"
echo "home: restored."
echo "  Binaries are not restored — reinstall as needed (e.g. claude-install)."
