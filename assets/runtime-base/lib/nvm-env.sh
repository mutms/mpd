#!/bin/bash
# nvm-env.sh — source this in scripts that need nvm.
# Provides: NVM_DIR, nvm function, node/npm in PATH.
# Usage: source /opt/mpd/assets/runtime-base/lib/nvm-env.sh

export NVM_DIR="$HOME/.nvm"
if [ ! -s "${NVM_DIR}/nvm.sh" ]; then
    echo "Error: nvm not found at ${NVM_DIR}/nvm.sh" >&2
    return 1 2>/dev/null || exit 1
fi
. "${NVM_DIR}/nvm.sh"
