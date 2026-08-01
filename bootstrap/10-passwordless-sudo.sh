#!/bin/bash
# bootstrap/10-passwordless-sudo.sh
#
# Wgettable. Self-contained. The ONLY script in the bootstrap chain that
# can be invoked interactively before the mpd repo is cloned, so it
# inlines its own helpers and hostname/OS gates instead of sourcing
# 00-common.sh.
#
# Behavior:
#   1. VM-name gate: hostname must be mpd-template, mpd-sandbox,
#      mpd-template-<suffix>, mpd-sandbox-<suffix>, or mpd-NNN (3-digit).
#      The -<suffix> forms exist so a developer can keep several
#      pre-takeover templates and sandboxes side by side (e.g.
#      mpd-template-trixie, mpd-sandbox-utm). The canonical mpd-NNN
#      hostname is set directly (at install, by cloud-init, or by the
#      developer) — mpd derives its identity from it. Refuses anything
#      else — accidental run on a workstation is fatal.
#   2. OS gate: Debian Trixie.
#   3. If `sudo -n true` already works (cloud-init / pre-prepped VM):
#      silent no-op.
#   4. Otherwise prompt for the root password (`su -c …`) and write
#      /etc/sudoers.d/00-mpd-<user> with NOPASSWD for the invoking user.
#      `su -c` is the privilege-rule-approved root elevation shape
#      (no identity switch to a non-root user).
#
# Standalone invocation:
#   bash <(wget -qO- https://raw.githubusercontent.com/<owner>/mpd/<branch>/bootstrap/10-passwordless-sudo.sh)

set -euo pipefail

# --- Inline helpers (can't source 00-common.sh; the repo may not exist yet) ---
step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

# --- VM-name gate ---
step "Hostname gate"
CURRENT_HOSTNAME="$(hostname -s 2>/dev/null || cat /etc/hostname | tr -d '[:space:]' | cut -d. -f1)"
case "${CURRENT_HOSTNAME}" in
    mpd-template|mpd-sandbox)             ;;
    mpd-template-?*|mpd-sandbox-?*)       ;;
    mpd-[0-9][0-9][0-9])                  ;;
    *)
        die "Refusing to run: hostname is '${CURRENT_HOSTNAME}', must be one of:
    mpd-template          mpd-template-<suffix>   (pre-takeover template VMs)
    mpd-sandbox           mpd-sandbox-<suffix>    (pre-takeover sandbox VMs)
    mpd-NNN  (3-digit)                            (post-takeover, managed)
Set it first, e.g.:
    sudo hostnamectl set-hostname mpd-sandbox-trixie
    sudo hostnamectl set-hostname mpd-template-parallels
Then log out + back in and re-run."
        ;;
esac
ok "hostname '${CURRENT_HOSTNAME}' accepted"

# --- OS gate ---
step "OS gate"
[ -r /etc/os-release ] || die "/etc/os-release missing — cannot verify OS."
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = "debian" ] \
    || die "bootstrap targets Debian (got ID=${ID:-unknown})."
[ "${VERSION_CODENAME:-}" = "trixie" ] \
    || die "bootstrap targets Debian Trixie (got VERSION_CODENAME=${VERSION_CODENAME:-unknown})."
ok "Debian Trixie"

# --- Passwordless sudo ---
step "Passwordless sudo for $(id -un)"

if sudo -n true 2>/dev/null; then
    ok "already configured (sudo -n works)"
    exit 0
fi

USER_NAME="$(id -un)"
SUDOERS_PATH="/etc/sudoers.d/00-mpd-${USER_NAME}"

echo "    No passwordless sudo for ${USER_NAME}. About to ask for the root password"
echo "    (one-time setup). The prompt comes from \`su\`."
echo

# `su - -c '<cmd>'` runs a single command as root in a login shell so
# root's own PATH (with /usr/sbin) is used — visudo lives there and is
# not on a regular user's PATH. visudo -cf validates the drop-in; if
# invalid the file is removed so subsequent sudo calls don't get
# bricked. Atomic via install -m 440.
if ! su - -c "
    set -e
    install -m 0440 -o root -g root /dev/null '${SUDOERS_PATH}'
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' '${USER_NAME}' > '${SUDOERS_PATH}'
    if ! visudo -cf '${SUDOERS_PATH}' >/dev/null; then
        rm -f '${SUDOERS_PATH}'
        echo 'visudo rejected the drop-in; removed.' >&2
        exit 1
    fi
"; then
    die "Failed to write ${SUDOERS_PATH}. Wrong root password, or the user '${USER_NAME}' isn't permitted to become root via su."
fi

sudo -n true 2>/dev/null \
    || die "Wrote ${SUDOERS_PATH} but \`sudo -n true\` still fails. Inspect manually."
ok "passwordless sudo enabled for ${USER_NAME}"
