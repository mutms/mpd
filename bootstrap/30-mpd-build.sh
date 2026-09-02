#!/bin/bash
# bootstrap/30-mpd-build.sh
#
# Checkout mpd repo and build mpd binary.
#
# Environment overrides:
#   MPD_REPO    https URL of the mpd repo (default: github.com/mutms/mpd)
#   MPD_BRANCH  branch / ref to check out (default: main)
#
#   bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/bootstrap/30-mpd-build.sh)

set -euo pipefail

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

REPO_URL="${MPD_REPO:-https://github.com/mutms/mpd.git}"
BRANCH="${MPD_BRANCH:-main}"
DEST="/opt/mpd"
STATE_DIR="/var/lib/mpd"
USER_NAME="$(id -un)"
GROUP_NAME="$(id -gn)"

step "Preconditions"
sudo -n true 2>/dev/null \
    || die "Passwordless sudo not configured. Run 10-passwordless-sudo.sh first."
command -v git >/dev/null 2>&1 \
    || die "git is not installed. Run 20-install-software.sh first."
ok "sudo -n works, git present"

step "FHS directories: ${DEST} + ${STATE_DIR} (owned by ${USER_NAME})"
sudo install -d -o "${USER_NAME}" -g "${GROUP_NAME}" -m 0755 "${DEST}"
sudo install -d -o "${USER_NAME}" -g "${GROUP_NAME}" -m 0755 "${STATE_DIR}"
ok "ready"

step "Clone or update ${REPO_URL} @ ${BRANCH} → ${DEST}"
if [ -d "${DEST}/.git" ]; then
    # Fetch from REPO_URL, not `origin` may have been changed to require SSH key.
    git -C "${DEST}" fetch --quiet "${REPO_URL}" "${BRANCH}"
    git -C "${DEST}" checkout --quiet "${BRANCH}"
    git -C "${DEST}" merge --ff-only --quiet FETCH_HEAD \
        || die "fast-forward from ${REPO_URL} (${BRANCH}) failed in ${DEST}. Resolve manually and re-run."
    ok "fast-forwarded to ${BRANCH}"
else
    git clone --branch "${BRANCH}" "${REPO_URL}" "${DEST}"
    ok "cloned"
fi

# Building first project that requires higher go versions installs it.
step "Building mpd"
[ -f "${DEST}/Makefile" ] || die "${DEST}/Makefile missing — repo not cloned correctly."
make -C "${DEST}" install
ok "built ${DEST}/bin/mpd"

# One managed line sourcing assets/vm/lib/bashrc-include.sh file.
step "mpd shell include (~/.bashrc)"
install -d "${HOME}/.local/bin"
BASHRC="${HOME}/.bashrc"
INCLUDE='[ -f /opt/mpd/assets/vm/lib/bashrc-include.sh ] && . /opt/mpd/assets/vm/lib/bashrc-include.sh  # mpd shell'
if grep -qxF "${INCLUDE}" "${BASHRC}" 2>/dev/null; then
    ok "${BASHRC} already sources the mpd shell include"
else
    tmp=$(mktemp)
    {
        printf '%s\n' "${INCLUDE}"
        cat "${BASHRC}" 2>/dev/null || true
    } > "${tmp}"
    [ -f "${BASHRC}" ] && chmod --reference="${BASHRC}" "${tmp}"
    mv "${tmp}" "${BASHRC}"
    ok "prepended the mpd shell include to ${BASHRC}"
fi

# Export PATH here too, to make mpd available in this session.
case ":${PATH}:" in
    *":/opt/mpd/bin:"*) ;;
    *) export PATH="/opt/mpd/bin:${PATH}" ;;
esac
