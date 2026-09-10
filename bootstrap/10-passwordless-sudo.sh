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

# The privileged work: write a NOPASSWD drop-in, validating it with visudo
# so an invalid file is removed rather than bricking sudo. Same body whether
# we reach root via `sudo` (user already a sudoer) or `su -` (minimal install,
# no sudo yet). $USER_NAME is expanded here, before it reaches root.
ROOT_WORK="
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
"

# Expert Debian installs often disable the root account. If the user is
# already a sudoer, elevate with their own password via sudo; only fall back
# to `su -` (root password) when sudo is absent or the user can't sudo.
if command -v sudo >/dev/null 2>&1 && sudo -v 2>/dev/null; then
    echo "    ${USER_NAME} can sudo. Making it passwordless (sudo may prompt once)."
    echo
    if ! sudo bash -c "${ROOT_WORK}"; then
        die "Failed to configure passwordless sudo for '${USER_NAME}' via sudo."
    fi
else
    echo "    No passwordless sudo for ${USER_NAME}. About to ask for the root password"
    echo "    (one-time setup — installs sudo if a minimal install lacks it)."
    echo "    The prompt comes from \`su\`."
    echo
    # `su - -c` runs as root with root's PATH, where visudo and usermod live.
    if ! su - -c "${ROOT_WORK}"; then
        die "Failed to configure sudo for '${USER_NAME}'. Wrong root password, the
user isn't permitted to become root via su, or sudo couldn't be installed."
    fi
fi

sudo -n true 2>/dev/null \
    || die "Wrote ${SUDOERS_PATH} but \`sudo -n true\` still fails. Inspect manually."
ok "passwordless sudo enabled for ${USER_NAME}"
