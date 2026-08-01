#!/bin/bash
# setup/mpd-prepare-takeover.sh
#
# Prepares a fresh Debian Trixie install — desktop OR server — to be
# adopted by the host-side `mpd-virt` orchestrator. Run it ON THE VM, as
# your dev user (NOT root).
#
# It may take a few runs with reboots in between to converge the network
# stack (a GNOME desktop ships NetworkManager, which mpd replaces with
# systemd-networkd + systemd-resolved). When every check is green it
# prints the exact command to run on the Mac:
#
#     mpd-virt takeover <NNN> <IP>
#
# reading both the id (from the hostname) and the IP off the VM, so you
# never type either by hand.
#
# Wgettable / self-contained: it runs before the mpd repo is cloned, so
# it inlines its own helpers rather than sourcing bootstrap/00-common.sh.
#
#   bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/setup/mpd-prepare-takeover.sh)
#
# Idempotent — safe to re-run after a partial step or a reboot.
#
# STATUS: steps 1–2 (hostname gate, passwordless sudo). The network-stack
# conversion, readiness check, and the printed takeover line land next.

set -euo pipefail

# --- Inline helpers (the mpd repo may not be cloned yet) --------------
step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

# --- 1. Hostname must be mpd-<NNN> -----------------------------------
# The hostname is mpd's single source of truth: the id, zone, subnet and
# every name derive from it. Managed ids are 100..254 (000 is the
# sandbox; 001..099 is the hypervisor DHCP pool). You set this at install
# time; prep only validates it.
step "Hostname"
host="$(hostname -s 2>/dev/null || cut -d. -f1 /etc/hostname | tr -d '[:space:]')"
case "${host}" in
    mpd-[0-9][0-9][0-9]) ;;
    *) die "hostname is '${host}', must be mpd-<NNN> (3-digit), e.g. mpd-137.
Set it and reboot:
    sudo hostnamectl set-hostname mpd-137" ;;
esac
nnn="${host#mpd-}"
id10="$((10#${nnn}))"    # force base-10 so a leading zero isn't read as octal
if [ "${id10}" -lt 100 ] || [ "${id10}" -gt 254 ]; then
    die "id ${nnn} is out of range. Managed VMs are 100..254.
(000 is the sandbox — use mpd-sandbox-setup.sh; 001..099 is the DHCP pool.)"
fi
ok "hostname '${host}' (id ${nnn})"

# --- OS gate: Debian Trixie ------------------------------------------
step "Operating system"
[ -r /etc/os-release ] || die "/etc/os-release missing — cannot verify the OS."
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = "debian" ] \
    || die "mpd targets Debian (got ID=${ID:-unknown})."
[ "${VERSION_CODENAME:-}" = "trixie" ] \
    || die "mpd targets Debian Trixie (got VERSION_CODENAME=${VERSION_CODENAME:-unknown})."
ok "Debian Trixie"

# --- 2. Passwordless sudo for the current (non-root) user ------------
# Takeover drives the VM over SSH as this user and never types a
# password, so `sudo -n` must be silent. Refuse root: the whole point is
# an unprivileged dev account that can escalate without a prompt.
step "Passwordless sudo for $(id -un)"
[ "$(id -u)" -ne 0 ] \
    || die "run this as your dev user, not root.
Takeover drives the VM as an unprivileged user over SSH; root has no
authorized key and no home for mpd to live in."

if sudo -n true 2>/dev/null; then
    ok "already configured (sudo -n works)"
else
    user_name="$(id -un)"
    sudoers_path="/etc/sudoers.d/00-mpd-${user_name}"
    echo "    No passwordless sudo for ${user_name}. Asking for the root password"
    echo "    (one-time setup — installs sudo if a minimal install lacks it)."
    echo "    The prompt below comes from \`su\`."
    echo

    # `su - -c` runs one command as root in a login shell, so root's PATH
    # (with /usr/sbin) finds visudo/usermod. A minimal Debian server
    # install ships neither sudo nor /etc/sudoers.d, so install sudo
    # first; a desktop install already has both. Then make the dev user a
    # real sudoer (sudo group) and drop in a NOPASSWD rule. visudo -cf
    # validates the drop-in; an invalid file is removed rather than left
    # to brick sudo. install -m 0440 writes it with the mode sudoers wants.
    if ! su - -c "
        set -e
        if ! command -v sudo >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq sudo
        fi
        install -d -m 0755 /etc/sudoers.d
        usermod -aG sudo '${user_name}'
        install -m 0440 -o root -g root /dev/null '${sudoers_path}'
        printf '%s ALL=(ALL) NOPASSWD:ALL\n' '${user_name}' > '${sudoers_path}'
        if ! visudo -cf '${sudoers_path}' >/dev/null; then
            rm -f '${sudoers_path}'
            echo 'visudo rejected the drop-in; removed.' >&2
            exit 1
        fi
    "; then
        die "Failed to configure sudo for '${user_name}'. Wrong root password, the
user isn't permitted to become root via su, or sudo couldn't be installed."
    fi

    sudo -n true 2>/dev/null \
        || die "Wrote ${sudoers_path} but \`sudo -n true\` still fails. Inspect manually."
    ok "passwordless sudo enabled for ${user_name}"
fi

echo
echo "Steps 1–2 complete for ${host}."
echo "Next steps (network-stack conversion, readiness, the takeover line) are not implemented yet."
