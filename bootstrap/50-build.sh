#!/bin/bash
# bootstrap/50-build.sh
#
# Build the in-VM `mpd` binary from this checkout and add bin/ to PATH.
# Idempotent — `make install` is fast when nothing changed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/00-common.sh"

REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

step "Building mpd"

[ -f "${REPO_DIR}/Makefile" ] \
    || die "${REPO_DIR}/Makefile missing — repo not cloned correctly."

cd "${REPO_DIR}"
make install
ok "built ${REPO_DIR}/bin/mpd"

# --- /opt/mpd/bin + ~/.local/bin on PATH (via ~/.bashrc) -------------
# ~/.bashrc covers every shell shape this VM's single dev user ever
# uses: login shells (via Debian's ~/.bash_profile → ~/.bashrc),
# interactive non-login (default), and sshd-invoked non-interactive
# (bash sources ~/.bashrc when stdin is a network socket). Prepending
# at the very top — before the standard "if not interactive, return"
# guard — lets all three pick it up.
#
# ~/.local/bin rides along: Debian only adds it via ~/.profile (login
# shells, guarded on the dir existing at login), so a CLI installed
# mid-session (claude-install) would otherwise need a re-login. We
# pre-create the dir and prepend unconditionally instead.
#
# Why not /etc/profile.d/: only fires for login shells, so
# `ssh user@vm cmd` (non-login) misses it.

step "mpd PATH + ~/.local/bin (~/.bashrc)"

install -d "${HOME}/.local/bin"

BASHRC="${HOME}/.bashrc"
SNIPPET='PATH="$HOME/.local/bin:/opt/mpd/bin:$PATH"  # mpd PATH'
if grep -qxF "${SNIPPET}" "${BASHRC}" 2>/dev/null; then
    ok "${BASHRC} already has mpd PATH snippet"
else
    tmp=$(mktemp)
    {
        printf '%s\n' "${SNIPPET}"
        # Drop superseded '# mpd PATH'-tagged snippet versions on update.
        grep -vF '# mpd PATH' "${BASHRC}" || true
    } > "${tmp}"
    chmod --reference="${BASHRC}" "${tmp}"
    mv "${tmp}" "${BASHRC}"
    ok "prepended mpd PATH to ${BASHRC}"
fi

# Drop the legacy /etc/profile.d/mpd.sh that earlier bootstraps may
# have written — superseded by the ~/.bashrc approach above.
if [ -f /etc/profile.d/mpd.sh ]; then
    sudo rm -f /etc/profile.d/mpd.sh
    ok "removed legacy /etc/profile.d/mpd.sh"
fi

# Also export PATH in this running shell so the rest of the bootstrap
# (and anything the user runs interactively after `bash 50-build.sh`)
# sees /opt/mpd/bin without having to start a new shell. Idempotent.
case ":${PATH}:" in
    *":/opt/mpd/bin:"*) ;;
    *) export PATH="/opt/mpd/bin:${PATH}" ;;
esac
