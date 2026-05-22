#!/bin/bash
# bootstrap/10-passwordless-sudo.sh
#
# Make `sudo` work without a password for the invoking user. The **only**
# bootstrap step that can be interactive — and only on a truly fresh
# Debian where the user isn't in the sudoers group yet. Once it's set up,
# the script is a silent no-op on subsequent runs.
#
# Interactive path: prompts the root password via `su -c '…'` and writes
# a NOPASSWD drop-in. `su -c` is the privilege-rule-approved root
# elevation shape (AGENTS.md §"Mandatory privilege rule") — no identity
# switch to a non-root user, no whole-script sudo wrapping.
#
# Non-interactive callers (e.g. mpd-virt's SSH-driven flow) work as long
# as the VM image they boot already has passwordless sudo configured —
# either via cloud-init, or by having been built from a template that
# went through this step at template-build time.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/00-common.sh"

step "Passwordless sudo"

if sudo -n true 2>/dev/null; then
    ok "passwordless sudo already configured for $(id -un)"
    exit 0
fi

USER_NAME="$(id -un)"
SUDOERS_PATH="/etc/sudoers.d/00-mpd-${USER_NAME}"

echo "    No passwordless sudo for ${USER_NAME}. About to ask for the root password"
echo "    (one-time setup). The root password prompt comes from \`su\`."
echo

# `su -c '<one cmd>'` runs the single command as root. The drop-in writes
# itself; `visudo -cf` validates it; if invalid the file is removed so
# subsequent sudo calls don't break. Atomic via install -m 0440.
if ! su -c "
    set -e
    install -m 0440 -o root -g root /dev/null '${SUDOERS_PATH}'
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' '${USER_NAME}' > '${SUDOERS_PATH}'
    chmod 0440 '${SUDOERS_PATH}'
    if ! visudo -cf '${SUDOERS_PATH}' >/dev/null; then
        rm -f '${SUDOERS_PATH}'
        echo 'visudo rejected the drop-in; removed.' >&2
        exit 1
    fi
"; then
    die "Failed to write ${SUDOERS_PATH}. Is the user '${USER_NAME}' typing the root password correctly?"
fi

# Verify sudo now works without a password.
if ! sudo -n true 2>/dev/null; then
    die "Wrote ${SUDOERS_PATH} but \`sudo -n true\` still fails. Inspect manually."
fi
ok "passwordless sudo enabled for ${USER_NAME}"
