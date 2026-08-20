#!/bin/bash
# Backup hook: the developer's home directory.
#
# Runs inside the runtime as the dev user, invoked by `mpd
# --runtime-backup` with the backup directory as $1 (a fresh
# /srv/backups/runtime/<timestamp>/). Idempotent — writes one archive,
# overwriting on re-run.
#
# A deny-list, not an allow-list: everything under $HOME is saved except
# the paths below. Two kinds are left out — regenerable caches, and
# installed binaries. Binaries are not carried across a rebuild on
# purpose: a rebuilt runtime gets fresh, current tools, and reinstalling
# one (e.g. `claude-install`) is a single command. So config, dotfiles,
# IDE settings, SSH known_hosts and shell history come back; caches and
# binaries do not.
set -euo pipefail

DEST="$1"
ARCHIVE="$DEST/home.tar.gz"

# Excluded paths, relative to $HOME. Caches and package stores
# (regenerable) plus installed binaries (reinstalled fresh, not restored).
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
)

args=()
for e in "${EXCLUDES[@]}"; do
    args+=(--exclude="./$e")
done
# node_modules can appear anywhere the dev works under $HOME.
args+=(--exclude="node_modules")

mkdir -p "$DEST"
# -C "$HOME" with "." stores paths relative, so restore is a clean untar
# into $HOME whatever the dev user is named.
set +e
tar -czf "$ARCHIVE" "${args[@]}" -C "$HOME" .
rc=$?
set -e
# tar exits 1 for "file changed as we read it" — routine on a live home
# (shell history, IDE state) and not a failure. 2 and up are real errors.
if [ "$rc" -gt 1 ]; then
    echo "home: tar failed (exit $rc)." >&2
    exit "$rc"
fi

echo "home: backed up ($(du -h "$ARCHIVE" | cut -f1))."
