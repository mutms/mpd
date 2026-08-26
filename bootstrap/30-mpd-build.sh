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
#   4. Installs Go into /usr/local/go when the VM has none on PATH.
#   5. `make install` → /opt/mpd/bin/mpd.
#   6. Puts /opt/mpd/bin, assets/vm/bin and ~/.local/bin on PATH via ~/.bashrc.
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
    # Update straight from REPO_URL, WITHOUT touching origin. The default
    # REPO_URL is public https, so the fetch needs no SSH key — that was the
    # whole reason origin used to be force-set to https here. But a developer
    # may have pointed origin at a git@ push URL (mutms-mpd-dev-setup does,
    # for push access), and clobbering that back to https on every adopt would
    # break their push and is plain rude. Fetching from the URL rather than
    # `origin` gets the keyless pull without disturbing their remote. (An
    # explicit MPD_REPO override is honoured the same way — it is simply the
    # URL fetched from.)
    git -C "${DEST}" fetch --quiet "${REPO_URL}" "${BRANCH}"
    git -C "${DEST}" checkout --quiet "${BRANCH}"
    git -C "${DEST}" merge --ff-only --quiet FETCH_HEAD \
        || die "fast-forward from ${REPO_URL} (${BRANCH}) failed in ${DEST}. Resolve manually and re-run."
    ok "fast-forwarded to ${BRANCH}"
else
    # install -d above made an empty dir; git clone into an empty
    # existing dir is fine.
    git clone --branch "${BRANCH}" "${REPO_URL}" "${DEST}"
    ok "cloned"
fi

# --- Go -----------------------------------------------------------------
# Upstream Go, not Debian's: the go.mod files name the version they need
# and the go command fetches that toolchain itself (GOTOOLCHAIN=auto), so
# this install only has to exist — any version works as the seed. Pinned
# with its checksums; bump both together. Skipped when a go is already on
# PATH (from this install, or anywhere else).
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
    # Symlinks, not a profile.d PATH entry: /usr/local/bin is on PATH in
    # every context — non-login ssh commands (mpd-virt), sudo, systemd —
    # while /etc/profile.d reaches login shells only.
    sudo ln -sfn /usr/local/go/bin/go /usr/local/bin/go
    sudo ln -sfn /usr/local/go/bin/gofmt /usr/local/bin/gofmt
    ok "installed $(go version) → /usr/local/go"
fi

step "Building mpd"
[ -f "${DEST}/Makefile" ] || die "${DEST}/Makefile missing — repo not cloned correctly."
make -C "${DEST}" install
ok "built ${DEST}/bin/mpd"

# --- mpd shell include (~/.bashrc) -------------------------------------
# One managed line, sourcing assets/vm/lib/bashrc-include.sh — which sets
# PATH (/opt/mpd/bin, assets/vm/bin, ~/.local/bin), sources the developer's
# vm.env, and adjusts the prompt. Everything mpd wants in the dev user's
# shell lives in that file, read live from /opt/mpd; ~/.bashrc carries only
# this one stable line, so mpd never re-edits the user's file after adoption.
#
# Prepended at the very top — before Debian's "if not interactive, return"
# guard — so it reaches every shell shape this VM's single dev user uses:
# login (Debian's ~/.bash_profile → ~/.bashrc), interactive non-login, and
# sshd-invoked non-interactive (bash sources ~/.bashrc when stdin is a
# socket — the shell mpd-virt drives the VM over, which must have
# /opt/mpd/bin on PATH). /etc/profile.d/ would miss `ssh user@vm cmd`.
#
# ~/.local/bin is pre-created here because Debian only adds it via ~/.profile
# at login (and only if it exists then), so a CLI installed mid-session
# (claude-install) would otherwise need a re-login.
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

# Also export PATH in this shell so whatever runs next in the same
# session sees /opt/mpd/bin without a new login.
case ":${PATH}:" in
    *":/opt/mpd/bin:"*) ;;
    *) export PATH="/opt/mpd/bin:${PATH}" ;;
esac
