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

# --- bin/ on PATH via /etc/profile.d ----------------------------------
# `bin/` ships dev helpers (demo, claude-install, gnome-start/stop) that
# users invoke by bare name. System-wide drop-in is the right shape:
# - applies to every login shell (the dev user, root, future ops users)
# - no per-user dotfile editing required
# - idempotent — re-running writes identical content.
step "bin/ on PATH (/etc/profile.d/mpd.sh)"

PROFILE_D=/etc/profile.d/mpd.sh
SNIPPET='# mpd: bin/ on PATH (system-wide, installed by bootstrap/50-build.sh)
if [ -d /opt/mpd/bin ] ; then
    PATH="/opt/mpd/bin:$PATH"
fi
'
if [ -f "${PROFILE_D}" ] && [ "$(sudo cat "${PROFILE_D}" 2>/dev/null || true)" = "${SNIPPET}" ]; then
    ok "${PROFILE_D} already in place"
else
    printf '%s' "${SNIPPET}" | sudo install -m 0644 /dev/stdin "${PROFILE_D}"
    ok "wrote ${PROFILE_D}"
fi
