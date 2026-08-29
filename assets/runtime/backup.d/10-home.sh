#!/bin/bash
# Backup hook: the developer's home directory. Invoked by
# `mpd --runtime-backup` with the backup directory as $1.
#
# A deny-list: everything under $HOME is saved except EXCLUDES below.
# Caches and installed binaries stay out on purpose — a rebuilt runtime
# reinstalls fresh tools (e.g. `claude-install`).
set -euo pipefail

DEST="$1"
ARCHIVE="$DEST/home.tar.gz"

# Paths relative to $HOME: regenerable caches plus installed binaries.
EXCLUDES=(
    ".cache"
    ".local/bin"
    ".npm"
    ".bun"
    ".cargo"
    ".rustup"
    ".composer/cache"
    "go/pkg"
    ".vscode-server"
    ".cursor-server"
    # IDE backends: gigabytes each, reinstalled by phpstorm-install-app.
    ".local/share/JetBrains/Toolbox/apps"
    # Seeded from the developer's mpd-virt overlay on every runtime create.
    "install"
)

args=()
for e in "${EXCLUDES[@]}"; do
    args+=(--exclude="./$e")
done
# node_modules can appear anywhere the dev works under $HOME.
args+=(--exclude="node_modules")

mkdir -p "$DEST"
# Store paths relative to $HOME, so restore is a plain untar for any user.
set +e
tar -czf "$ARCHIVE" "${args[@]}" -C "$HOME" .
rc=$?
set -e
# tar exits 1 for "file changed as we read it" — routine on a live home,
# not a failure. 2 and up are real errors.
if [ "$rc" -gt 1 ]; then
    echo "home: tar failed (exit $rc)." >&2
    exit "$rc"
fi

echo "home: backed up ($(du -h "$ARCHIVE" | cut -f1))."
