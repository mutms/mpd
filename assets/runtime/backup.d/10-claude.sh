#!/bin/bash
# Backup hook: Claude Code configuration.
#
# Runs inside the runtime as the dev user, invoked by `mpd
# --runtime-backup` with the backup directory as $1 (a fresh
# /srv/backups/runtime/<timestamp>/). Each hook owns one topic and must
# be idempotent — re-running into the same directory just overwrites.
set -euo pipefail

DEST="$1/claude"

if [ ! -d "$HOME/.claude" ] && [ ! -f "$HOME/.claude.json" ]; then
    echo "claude: nothing to back up."
    exit 0
fi
mkdir -p "$DEST"
if [ -d "$HOME/.claude" ]; then
    cp -a "$HOME/.claude" "$DEST/"
fi
if [ -f "$HOME/.claude.json" ]; then
    cp -a "$HOME/.claude.json" "$DEST/"
fi
echo "claude: backed up."
