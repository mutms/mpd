#!/bin/bash
# bootstrap/20-git-clone.sh
#
# Wgettable. Self-contained. Runs AFTER 10-passwordless-sudo.sh has
# made `sudo` silent (or cloud-init has).
#
#   1. Asserts `sudo -n true` works.
#   2. apt-installs `git` + `ca-certificates`.
#   3. Ensures /opt/mpd + /var/lib/mpd exist, owned by the dev user.
#   4. Clones (or fast-forwards) the mpd repo into /opt/mpd.
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
DEST="/opt/mpd"
STATE_DIR="/var/lib/mpd"
USER_NAME="$(id -un)"
GROUP_NAME="$(id -gn)"

step "Sudo precondition"
sudo -n true 2>/dev/null \
    || die "Passwordless sudo not configured. Run 10-passwordless-sudo.sh first."
ok "sudo -n true works"

step "FHS directories: ${DEST} + ${STATE_DIR} (owned by ${USER_NAME})"
# install -d is idempotent — creates the dir if missing, leaves alone if
# present (and re-applies mode/owner). Chown'd to the dev user so git
# clone, make install, mpd --setup all run without sudo from here on.
# Subdirs (conf/, env/, state/) are created later by mpd --setup as
# needed and inherit the parent owner.
sudo install -d -o "${USER_NAME}" -g "${GROUP_NAME}" -m 0755 "${DEST}"
sudo install -d -o "${USER_NAME}" -g "${GROUP_NAME}" -m 0755 "${STATE_DIR}"
ok "${DEST} + ${STATE_DIR} ready (owner=${USER_NAME})"

step "Install git + ca-certificates"
need_install=()
dpkg -s git              >/dev/null 2>&1 || need_install+=(git)
dpkg -s ca-certificates  >/dev/null 2>&1 || need_install+=(ca-certificates)
if [ ${#need_install[@]} -gt 0 ]; then
    # -o DPkg::Lock::Timeout: apt-get (unlike `apt`) has no default lock
    # wait, so a desktop template's packagekitd checking for updates makes
    # this fail outright. -o Acquire::Retries: recover a stalled fetch
    # instead of failing the step. Inlined rather than shared: this script
    # is wgettable and runs before the repo exists.
    APT_OPTS="-o DPkg::Lock::Timeout=300 -o Acquire::Retries=3"
    # shellcheck disable=SC2086
    sudo env DEBIAN_FRONTEND=noninteractive apt-get $APT_OPTS update -qq
    # shellcheck disable=SC2086
    sudo env DEBIAN_FRONTEND=noninteractive apt-get $APT_OPTS install -y --no-install-recommends \
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
    # `${DEST}` was just install -d'd above (owned by the dev user); git
    # clone into a non-empty existing dir is supported as long as the dir
    # itself is empty — install -d created an empty dir, so this just works.
    git clone --branch "${BRANCH}" "${REPO_URL}" "${DEST}"
    ok "cloned ${REPO_URL} (${BRANCH}) → ${DEST}"
fi
