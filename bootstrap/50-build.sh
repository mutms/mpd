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

# --- bin/ on PATH via ~/.bashrc ---------------------------------------
# `bin/` ships dev helpers (demo, claude-install, gnome-start/stop) that
# users invoke by bare name. Add a conditional PATH line to ~/.bashrc —
# matches Debian's stock ~/.profile snippet for ~/.local/bin. Idempotent:
# marker comment is the dedupe key, re-runs no-op.
step "bin/ on PATH (~/.bashrc)"

BASHRC="${HOME}/.bashrc"
MARKER='# mpd: bin/ on PATH'
SNIPPET="
${MARKER}
if [ -d \"\$HOME/Developer/mpd/bin\" ] ; then
    PATH=\"\$HOME/Developer/mpd/bin:\$PATH\"
fi
"
if [ -f "${BASHRC}" ] && grep -qF "${MARKER}" "${BASHRC}"; then
    ok "${BASHRC} already has the PATH snippet"
else
    printf '%s' "${SNIPPET}" >> "${BASHRC}"
    ok "appended PATH snippet to ${BASHRC}"
fi
