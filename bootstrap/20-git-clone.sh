#!/bin/bash
# bootstrap/20-git-clone.sh
#
# Wgettable. Self-contained. Runs AFTER 10-passwordless-sudo.sh has
# made `sudo` silent (or cloud-init has).
#
#   1. Asserts `sudo -n true` works.
#   2. apt-installs `git` + `ca-certificates`.
#   3. Clones (or fast-forwards) the mpd repo into ~/Developer/mpd.
#
# No hostname gate — 10 already validated; 20 is just a worker.
#
# Environment overrides:
#   MPD_REPO    full https URL of the mpd repo (default: github.com/mutms/mpd)
#   MPD_BRANCH  branch / ref to check out (default: main)
#
# Standalone invocation:
#   bash <(wget -qO- https://raw.githubusercontent.com/<owner>/mpd/<branch>/bootstrap/20-git-clone.sh)

set -euo pipefail

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

REPO_URL="${MPD_REPO:-https://github.com/mutms/mpd.git}"
BRANCH="${MPD_BRANCH:-main}"
DEST="${HOME}/Developer/mpd"

step "Sudo precondition"
sudo -n true 2>/dev/null \
    || die "Passwordless sudo not configured. Run 10-passwordless-sudo.sh first."
ok "sudo -n true works"

step "Install git + ca-certificates"
need_install=()
dpkg -s git              >/dev/null 2>&1 || need_install+=(git)
dpkg -s ca-certificates  >/dev/null 2>&1 || need_install+=(ca-certificates)
if [ ${#need_install[@]} -gt 0 ]; then
    sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        "${need_install[@]}"
    ok "installed: ${need_install[*]}"
else
    ok "git + ca-certificates already installed"
fi

step "Clone or update ${REPO_URL} @ ${BRANCH} → ${DEST}"
if [ -d "${DEST}/.git" ]; then
    git -C "${DEST}" remote set-url origin "${REPO_URL}"
    git -C "${DEST}" fetch --quiet origin "${BRANCH}"
    git -C "${DEST}" checkout --quiet "${BRANCH}"
    git -C "${DEST}" pull --ff-only --quiet origin "${BRANCH}" \
        || die "git pull --ff-only failed in ${DEST}. Resolve manually and re-run."
    ok "fast-forwarded ${DEST} to origin/${BRANCH}"
else
    mkdir -p "$(dirname "${DEST}")"
    git clone --branch "${BRANCH}" "${REPO_URL}" "${DEST}"
    ok "cloned ${REPO_URL} (${BRANCH}) → ${DEST}"
fi
