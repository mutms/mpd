#!/bin/bash
# bootstrap/10-passwordless-sudo.sh
#
# Give the invoking dev user passwordless sudo.
#
#   bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/bootstrap/10-passwordless-sudo.sh)

set -euo pipefail

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

# The -<suffix> forms let several pre-adoption templates and sandboxes
# coexist (mpd-template-trixie, mpd-sandbox-utm).
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

step "OS gate"
[ -r /etc/os-release ] || die "/etc/os-release missing — cannot verify OS."
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = "debian" ] \
    || die "bootstrap targets Debian (got ID=${ID:-unknown})."
[ "${VERSION_CODENAME:-}" = "trixie" ] \
    || die "bootstrap targets Debian Trixie (got VERSION_CODENAME=${VERSION_CODENAME:-unknown})."
ok "Debian Trixie"

step "Passwordless sudo for $(id -un)"
[ "$(id -u)" -ne 0 ] || die "run this as your dev user, not root."

# A minimal server install has no sudo; probe only when the command exists.
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

# `su - -c` runs the command as root with root's PATH, where visudo and
# usermod live. visudo -cf validates the drop-in; an invalid file is
# removed so sudo is not bricked.
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
