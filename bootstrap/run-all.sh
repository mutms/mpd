#!/bin/bash
# bootstrap/run-all.sh
#
# Run every bootstrap step in order. Single entry point for callers
# (setup/sandbox/take-over-sandbox-vm.sh and mpd-virt's create verb).
#
# Usage:
#   bash bootstrap/run-all.sh <NNN>
#     <NNN>   3-digit octet identifying the VM:
#               000          sandbox VM (DHCP IP)
#               100..254     managed VM (static IP <subnet>.<NNN>)
#
# Idempotent. Interactive only at step 10 on a truly fresh Debian
# (one-time root password prompt via `su -c`). Every subsequent run is
# silent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/00-common.sh"

[ $# -eq 1 ] || die "Usage: bash bootstrap/run-all.sh <NNN>   (NNN = 000 or 100..254)"
OCTET="$1"

# --- Preflight gates -------------------------------------------------
# Fire before any sudo work happens — fail fast on hosts that can't be
# brought to the target end state.
require_debian_trixie
require_accepted_hostname

# --- Steps -----------------------------------------------------------
# Each step is a separate process so a failure exits with that step's
# message. Numbered prefix preserves order.
bash "${SCRIPT_DIR}/10-passwordless-sudo.sh"
bash "${SCRIPT_DIR}/20-networking.sh"          "${OCTET}"
bash "${SCRIPT_DIR}/30-install-software.sh"
bash "${SCRIPT_DIR}/40-build.sh"
bash "${SCRIPT_DIR}/50-wireguard.sh"

step "Bootstrap complete"
ok "VM is ready for \`mpd --setup\`"
