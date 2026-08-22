#!/bin/bash
# bootstrap/30-mpd-build.sh
#
# Step 3 of 3. Wgettable, self-contained — it is what puts the repo on
# the box, so it cannot come from the repo.
#
#   1. Asserts passwordless sudo (step 1) and git (step 2).
#   2. Creates /opt/mpd + /var/lib/mpd, owned by the dev user.
#   3. Clones the mpd repo into /opt/mpd, or fast-forwards an existing
#      checkout (refuses on a dirty tree — resolve by hand).
#   4. `make install` → /opt/mpd/bin/mpd.
#   5. Puts /opt/mpd/bin and ~/.local/bin on PATH via ~/.bashrc.
#
# Idempotent: a current checkout costs a fetch and a `make install` that
# finds nothing to do.
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
# install -d is idempotent — creates the dir if missing, leaves it alone
# if present (re-applying mode/owner). Owned by the dev user so git,
# make install and mpd --vm-setup run without sudo from here on. The
# subdirs of /var/lib/mpd (conf/, env/, state/) are created by
# mpd --vm-setup as needed.
sudo install -d -o "${USER_NAME}" -g "${GROUP_NAME}" -m 0755 "${DEST}"
sudo install -d -o "${USER_NAME}" -g "${GROUP_NAME}" -m 0755 "${STATE_DIR}"
ok "ready"

step "Clone or update ${REPO_URL} @ ${BRANCH} → ${DEST}"
if [ -d "${DEST}/.git" ]; then
    git -C "${DEST}" remote set-url origin "${REPO_URL}"
    git -C "${DEST}" fetch --quiet origin "${BRANCH}"
    git -C "${DEST}" checkout --quiet "${BRANCH}"
    git -C "${DEST}" pull --ff-only --quiet origin "${BRANCH}" \
        || die "git pull --ff-only failed in ${DEST}. Resolve manually and re-run."
    ok "fast-forwarded to origin/${BRANCH}"
else
    # install -d above made an empty dir; git clone into an empty
    # existing dir is fine.
    git clone --branch "${BRANCH}" "${REPO_URL}" "${DEST}"
    ok "cloned"
fi

step "Building mpd"
[ -f "${DEST}/Makefile" ] || die "${DEST}/Makefile missing — repo not cloned correctly."
make -C "${DEST}" install
ok "built ${DEST}/bin/mpd"

# --- /opt/mpd/bin + ~/.local/bin on PATH (via ~/.bashrc) --------------
# ~/.bashrc covers every shell shape this VM's single dev user uses:
# login shells (Debian's ~/.bash_profile → ~/.bashrc), interactive
# non-login, and sshd-invoked non-interactive (bash sources ~/.bashrc
# when stdin is a network socket). Prepending at the very top — before
# the standard "if not interactive, return" guard — lets all three pick
# it up. /etc/profile.d/ would miss `ssh user@vm cmd` (non-login).
#
# ~/.local/bin rides along: Debian only adds it via ~/.profile (login
# shells, and only if the dir exists at login), so a CLI installed
# mid-session (claude-install) would otherwise need a re-login. Pre-create
# the dir and prepend unconditionally instead.
step "PATH (~/.bashrc)"
install -d "${HOME}/.local/bin"
BASHRC="${HOME}/.bashrc"
SNIPPET='PATH="$HOME/.local/bin:/opt/mpd/bin:$PATH"  # mpd PATH'
if grep -qxF "${SNIPPET}" "${BASHRC}" 2>/dev/null; then
    ok "${BASHRC} already has the mpd PATH line"
else
    tmp=$(mktemp)
    {
        printf '%s\n' "${SNIPPET}"
        # Drop any older '# mpd PATH'-tagged line on the way.
        grep -vF '# mpd PATH' "${BASHRC}" 2>/dev/null || true
    } > "${tmp}"
    [ -f "${BASHRC}" ] && chmod --reference="${BASHRC}" "${tmp}"
    mv "${tmp}" "${BASHRC}"
    ok "prepended the mpd PATH line to ${BASHRC}"
fi

# Also export PATH in this shell so whatever runs next in the same
# session sees /opt/mpd/bin without a new login.
case ":${PATH}:" in
    *":/opt/mpd/bin:"*) ;;
    *) export PATH="/opt/mpd/bin:${PATH}" ;;
esac
