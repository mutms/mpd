#!/bin/bash
# Restore hook: the developer's home directory. Inverse of
# backup.d/10-home.sh; $1 is the backup directory to restore from.
# No-ops cleanly when the backup carries no home archive.
#
# A plain untar over the current home: config, dotfiles, IDE settings,
# SSH known_hosts and shell history come back. Binaries were left out of
# the backup on purpose and are NOT restored — reinstall the ones you
# want fresh (e.g. `claude-install`).
set -euo pipefail

ARCHIVE="$1/home.tar.gz"
if [ ! -f "$ARCHIVE" ]; then
    echo "home: nothing to restore."
    exit 0
fi

tar -xzf "$ARCHIVE" -C "$HOME"
echo "home: restored."
echo "  Binaries are not restored — reinstall as needed (e.g. claude-install)."
