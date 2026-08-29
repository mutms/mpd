#!/bin/bash
# bootstrap/30-mpd-build.sh
#
# Step 3 of 3, wgettable and self-contained — it puts the repo on the
# box, so it cannot come from the repo. Clones or fast-forwards
# /opt/mpd, installs Go when none is on PATH, builds bin/mpd, and wires
# the mpd shell include into ~/.bashrc.
# Needs steps 1 (sudo) and 2 (git). Idempotent.
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
# Owned by the dev user so git, make install and mpd --vm-setup need no
# sudo from here on. The subdirs of /var/lib/mpd are created by
# mpd --vm-setup as needed.
sudo install -d -o "${USER_NAME}" -g "${GROUP_NAME}" -m 0755 "${DEST}"
sudo install -d -o "${USER_NAME}" -g "${GROUP_NAME}" -m 0755 "${STATE_DIR}"
ok "ready"

step "Clone or update ${REPO_URL} @ ${BRANCH} → ${DEST}"
if [ -d "${DEST}/.git" ]; then
    # Fetch from REPO_URL, not `origin`: the default is public https (no
    # SSH key needed), and a developer may have pointed origin at a git@
    # push URL that must not be clobbered.
    git -C "${DEST}" fetch --quiet "${REPO_URL}" "${BRANCH}"
    git -C "${DEST}" checkout --quiet "${BRANCH}"
    git -C "${DEST}" merge --ff-only --quiet FETCH_HEAD \
        || die "fast-forward from ${REPO_URL} (${BRANCH}) failed in ${DEST}. Resolve manually and re-run."
    ok "fast-forwarded to ${BRANCH}"
else
    # The dir exists (install -d above) but is empty; clone accepts that.
    git clone --branch "${BRANCH}" "${REPO_URL}" "${DEST}"
    ok "cloned"
fi

# Upstream Go as the seed toolchain; go.mod picks the real compiler (see
# AGENTS.md "Change discipline"). Pinned with checksums — bump both
# together. Skipped when a go is already on PATH.
GO_VERSION="1.27.0"
case "$(dpkg --print-architecture)" in
    amd64) GO_ARCH=amd64; GO_SHA256=675c26c449cbb18fc24b74650de1eabbae6e16f64326fd85a283fb3b58280685 ;;
    arm64) GO_ARCH=arm64; GO_SHA256=51798d2c42d0e1c6ed7fd9f48728b4193abac9e8aad6dbac2fe96a81f5909bda ;;
    *) die "unsupported architecture $(dpkg --print-architecture)" ;;
esac

step "Go"
if command -v go >/dev/null 2>&1; then
    ok "$(go version) on PATH"
else
    tarball="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
    tmp="$(mktemp -d)"
    wget -qO "${tmp}/${tarball}" "https://go.dev/dl/${tarball}" \
        || die "download of ${tarball} failed"
    echo "${GO_SHA256}  ${tmp}/${tarball}" | sha256sum -c --quiet \
        || die "${tarball}: checksum mismatch"
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "${tmp}/${tarball}"
    rm -rf "${tmp}"
    # Symlinks, not a profile.d PATH entry: /usr/local/bin is on PATH for
    # non-login ssh commands, sudo and systemd; /etc/profile.d reaches
    # login shells only.
    sudo ln -sfn /usr/local/go/bin/go /usr/local/bin/go
    sudo ln -sfn /usr/local/go/bin/gofmt /usr/local/bin/gofmt
    ok "installed $(go version) → /usr/local/go"
fi

step "Building mpd"
[ -f "${DEST}/Makefile" ] || die "${DEST}/Makefile missing — repo not cloned correctly."
make -C "${DEST}" install
ok "built ${DEST}/bin/mpd"

# One managed line sourcing assets/vm/lib/bashrc-include.sh, prepended
# at the very top of ~/.bashrc — before Debian's non-interactive return
# guard — so `ssh user@vm cmd` shells get PATH too; see that file's
# header. mpd never re-edits ~/.bashrc after adoption.
# ~/.local/bin is pre-created: Debian adds it to PATH via ~/.profile only
# when it exists at login, so a CLI installed mid-session would
# otherwise need a re-login.
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

# Export PATH here too, so the rest of this session sees /opt/mpd/bin
# without a new login.
case ":${PATH}:" in
    *":/opt/mpd/bin:"*) ;;
    *) export PATH="/opt/mpd/bin:${PATH}" ;;
esac
