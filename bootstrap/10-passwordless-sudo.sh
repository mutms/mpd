#!/bin/bash
# bootstrap/10-passwordless-sudo.sh
#
# Step 1 of 3. Wgettable, self-contained — it runs on a box that has
# nothing of mpd on it yet, so it inlines its helpers and gates.
#
# What it does:
#   1. Hostname gate: mpd-template, mpd-sandbox, mpd-template-<suffix>,
#      mpd-sandbox-<suffix>, or mpd-NNN (3-digit). The -<suffix> forms
#      let a developer keep several pre-adoption templates and sandboxes
#      side by side (mpd-template-trixie, mpd-sandbox-utm). The canonical
#      mpd-NNN hostname is set directly (at install, by cloud-init, or by
#      the developer) — mpd derives its identity from it. Anything else
#      is refused: an accidental run on a workstation is fatal.
#   2. OS gate: Debian Trixie. Refuses root: the point is an unprivileged
#      dev account that can escalate without a prompt.
#   3. If `sudo -n true` already works (cloud-init / pre-prepped VM /
#      template): silent no-op.
#   4. Otherwise ask for the root password once (`su - -c`), install sudo
#      when a minimal netinst lacks it, put the user in the sudo group and
#      write /etc/sudoers.d/00-mpd-<user> with NOPASSWD. `su -c` is the
#      privilege-rule-approved root elevation (no identity switch to a
#      non-root user).
#
# Idempotent: the fast path is one `sudo -n true`.
#
#   bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/bootstrap/10-passwordless-sudo.sh)

set -euo pipefail

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

# --- Hostname gate ---
step "Hostname gate"
CURRENT_HOSTNAME="$(hostname -s 2>/dev/null || cut -d. -f1 /etc/hostname | tr -d '[:space:]')"
case "${CURRENT_HOSTNAME}" in
    mpd-template|mpd-sandbox)             ;;
    mpd-template-?*|mpd-sandbox-?*)       ;;
    mpd-[0-9][0-9][0-9])                  ;;
    *)
        die "Refusing to run: hostname is '${CURRENT_HOSTNAME}', must be one of:
    mpd-template          mpd-template-<suffix>   (pre-adoption template VMs)
    mpd-sandbox           mpd-sandbox-<suffix>    (pre-adoption sandbox VMs)
    mpd-NNN  (3-digit)                            (post-adoption, managed)
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
[ "$(id -u)" -ne 0 ] || die "run this as your dev user, not root."

# Guard the probe with `command -v`: a minimal server install has no sudo
# at all, and calling it would just print "command not found".
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    ok "already configured (sudo -n works)"
    exit 0
fi

USER_NAME="$(id -un)"
SUDOERS_PATH="/etc/sudoers.d/00-mpd-${USER_NAME}"

echo "    No passwordless sudo for ${USER_NAME}. About to ask for the root password"
echo "    (one-time setup — installs sudo if a minimal install lacks it)."
echo "    The prompt comes from \`su\`."
echo

# `su - -c '<cmd>'` runs a single command as root in a login shell so
# root's own PATH (with /usr/sbin) is used — visudo and usermod live
# there and are not on a regular user's PATH. visudo -cf validates the
# drop-in; if invalid the file is removed so subsequent sudo calls don't
# get bricked. Atomic via install -m 440.
if ! su - -c "
    set -e
    if ! command -v sudo >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq sudo
    fi
    install -d -m 0755 /etc/sudoers.d
    usermod -aG sudo '${USER_NAME}'
    install -m 0440 -o root -g root /dev/null '${SUDOERS_PATH}'
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' '${USER_NAME}' > '${SUDOERS_PATH}'
    if ! visudo -cf '${SUDOERS_PATH}' >/dev/null; then
        rm -f '${SUDOERS_PATH}'
        echo 'visudo rejected the drop-in; removed.' >&2
        exit 1
    fi
"; then
    die "Failed to configure sudo for '${USER_NAME}'. Wrong root password, the
user isn't permitted to become root via su, or sudo couldn't be installed."
fi

sudo -n true 2>/dev/null \
    || die "Wrote ${SUDOERS_PATH} but \`sudo -n true\` still fails. Inspect manually."
ok "passwordless sudo enabled for ${USER_NAME}"
