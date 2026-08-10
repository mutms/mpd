#!/bin/bash
# Restore hook: Claude Code. Inverse of backup.d/10-claude.sh; $1 is the
# backup directory to restore from. No-ops cleanly when the backup
# carries nothing for this topic.
#
# Only CONFIGURATION is restored. The binary is deliberately not carried
# across a rebuild — a rebuilt runtime reinstalls everything fresh, so
# this re-runs claude-install (idempotent, fetches the current release)
# instead of copying a stale ~/.local/bin/claude back in.
set -euo pipefail

SRC="$1/claude"

if [ ! -d "$SRC" ]; then
    echo "claude: nothing to restore."
    exit 0
fi
if [ -d "$SRC/.claude" ]; then
    rm -rf "$HOME/.claude"
    cp -a "$SRC/.claude" "$HOME/"
fi
if [ -f "$SRC/.claude.json" ]; then
    cp -a "$SRC/.claude.json" "$HOME/"
fi
echo "claude: configuration restored."

bash /opt/mpd/assets/runtime/tools/claude-install
