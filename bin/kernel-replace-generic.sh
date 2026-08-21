#!/bin/bash
# kernel-replace-generic.sh — TEMPORARY, and deliberately named so.
#
# Swaps Debian's *cloud* kernel for the *generic* one on an mpd VM that
# was built before mpd pinned the right image. Delete it once your VMs are
# migrated: new VMs no longer need it, because setup/linux, setup/windows
# and mpd-virt all pin the "generic" image variant now.
#
# WHY. Debian's cloud kernel ships no DRM drivers at all — its
# drivers/gpu/drm/ module directory is empty. A VM running it has no
# /dev/dri, so the text console works while anything graphical (gdm, a
# Wayland greeter) is a black screen with nothing useful in any log. The
# generic kernel carries the full driver set.
#
# WHO NEEDS IT. Only a VM whose hypervisor console you want to show a
# desktop. A headless mpd VM is perfectly happy on the cloud kernel, and
# so is `rdp-start` — xorgxrdp's X server is virtual and never touches
# DRM. `mpd --vm-diag` tells you which VMs are affected.
#
# TWO PHASES, one reboot between them. Run it, reboot, run it again:
#
#   phase 1 (on the cloud kernel)  install generic, pin grub, stop here
#   ... mpd --vm-restart ...
#   phase 2 (on the generic kernel) purge the cloud kernel, unpin grub
#
# It never reboots for you — that is yours to time — and it never removes
# the kernel you are currently running.
#
# Deliberately NOT executable, and deliberately suffixed .sh: it is not an
# mpd tool and must not be reachable by tab-completing PATH. Run it the
# long way, on purpose:
#
#   bash /opt/mpd/bin/kernel-replace-generic.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../bootstrap/00-common.sh"

usage() {
    cat <<'EOF'
Usage: bash /opt/mpd/bin/kernel-replace-generic.sh [--yes]

Replace Debian's cloud kernel with the generic one, so this VM's console
can render a desktop. Run it, reboot with `mpd --vm-restart`, run it again.

  --yes, -y   do not ask before changing anything

Safe to re-run at any point: it reports what phase it is in and does only
what is left.
EOF
}

ASSUME_YES=0
case "${1:-}" in
    -y | --yes) ASSUME_YES=1 ;;
    -h | --help)
        usage
        exit 0
        ;;
    "") ;;
    *) die "Unknown argument: $1 (accepts --yes)" ;;
esac

confirm() {
    [ "${ASSUME_YES}" = 1 ] && return 0
    [ -t 0 ] || die "Not a terminal — re-run interactively, or pass --yes."
    read -r -p "$1 [y/N] " reply
    case "${reply}" in
        y | Y | yes | YES) return 0 ;;
        *) die "Cancelled." ;;
    esac
}

command -v dpkg >/dev/null 2>&1 || die "Not a Debian system."

ARCH="$(dpkg --print-architecture)"
GENERIC_PKG="linux-image-${ARCH}"
CLOUD_PKG="linux-image-cloud-${ARCH}"
RUNNING="$(uname -r)"
GRUB_DEFAULTS=/etc/default/grub
GRUB_BAK="${GRUB_DEFAULTS}.kernel-replace-bak"

installed() { dpkg -s "$1" >/dev/null 2>&1; }

# Every installed kernel image package built from the cloud flavour.
cloud_images() {
    dpkg-query -W -f '${Package} ${Status}\n' 'linux-image-*' 2>/dev/null \
        | awk '$NF == "installed" { print $1 }' \
        | grep -- "-cloud-${ARCH}\$" || true
}

step "This VM"
ok "architecture ${ARCH}"
ok "running kernel ${RUNNING}"

case "${RUNNING}" in
    *-cloud-*) PHASE=1 ;;
    *) PHASE=2 ;;
esac

# --- Phase 2: already on the generic kernel ----------------------------
# Reached either after the reboot, or on a VM that never had the problem.
if [ "${PHASE}" = 2 ]; then
    ok "this is not a cloud kernel — nothing to boot into"

    leftovers="$(cloud_images)"
    pinned=0
    grep -q '^GRUB_DEFAULT="gnulinux' "${GRUB_DEFAULTS}" 2>/dev/null && pinned=1

    if [ -z "${leftovers}" ] && [ "${pinned}" = 0 ] && [ ! -f "${GRUB_BAK}" ]; then
        step "Result"
        ok "nothing to do — this VM is already on the generic kernel"
        exit 0
    fi

    step "Cleanup"
    if [ -n "${leftovers}" ]; then
        echo "    cloud kernel image(s) still installed:"
        printf '      %s\n' ${leftovers}
        confirm "Purge them?"
        # Belt and braces: the running kernel can never match here (it has
        # no -cloud in its name), but purging a running kernel is the one
        # irreversible mistake this script could make, so assert it.
        for pkg in ${leftovers}; do
            case "${pkg}" in
                *"${RUNNING}"*) die "refusing to remove ${pkg} — it is the running kernel" ;;
            esac
        done
        # shellcheck disable=SC2086
        apt_get purge -y ${leftovers}
        ok "purged"
    else
        ok "no cloud kernel images installed"
    fi

    step "Boot selection"
    if [ -f "${GRUB_BAK}" ]; then
        sudo cp "${GRUB_BAK}" "${GRUB_DEFAULTS}"
        sudo rm -f "${GRUB_BAK}"
        ok "restored ${GRUB_DEFAULTS} from the phase-1 backup"
    elif [ "${pinned}" = 1 ]; then
        sudo sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT=0|' "${GRUB_DEFAULTS}"
        ok "reset GRUB_DEFAULT=0 (no backup found)"
    else
        ok "GRUB_DEFAULT already unpinned"
    fi
    sudo update-grub >/dev/null 2>&1
    ok "grub.cfg regenerated"

    step "Result"
    if compgen -G "/dev/dri/card*" >/dev/null; then
        ok "graphics device present — 'gnome-install' will render"
    else
        warn "still no /dev/dri — this VM's display adapter has no driver in the generic kernel either"
    fi
    echo
    echo "Done. Confirm with: mpd --vm-diag"
    echo "This script has nothing left to do on this VM."
    exit 0
fi

# --- Phase 1: on the cloud kernel --------------------------------------
warn "this kernel ships no DRM drivers — a desktop here shows a black console"

step "Plan"
cat <<EOF
    1. install ${GENERIC_PKG}
    2. purge ${CLOUD_PKG} (the metapackage, so no new cloud kernels arrive)
    3. mark linux-image-${RUNNING} manual, so autoremove cannot delete
       the kernel you are still running
    4. point grub at the generic entry for the next boot
    5. stop, so you can reboot when it suits you

Nothing is rebooted, and the running kernel is not removed.
EOF
confirm "Proceed?"

step "Install ${GENERIC_PKG}"
if installed "${GENERIC_PKG}"; then
    ok "already installed"
else
    apt_get update -qq
    apt_get install -y "${GENERIC_PKG}"
    ok "installed"
fi

step "Stop new cloud kernels arriving"
# Mark first, purge second. The running image package has to survive until
# after the reboot, and purging the metapackage is what makes it look
# autoremovable — so pin it as manual before that becomes true, not after.
sudo apt-mark manual "linux-image-${RUNNING}" >/dev/null 2>&1 \
    && ok "linux-image-${RUNNING} marked manual (kept until after the reboot)" \
    || warn "could not mark linux-image-${RUNNING} manual — avoid 'apt autoremove' before rebooting"

if installed "${CLOUD_PKG}"; then
    apt_get purge -y "${CLOUD_PKG}"
    ok "purged the ${CLOUD_PKG} metapackage"
else
    ok "${CLOUD_PKG} not installed"
fi

step "Point grub at the generic kernel"
# GRUB_DEFAULT=0 is not enough: `linux-version sort` ranks -cloud-<arch>
# ABOVE -<arch> at equal version, so entry 0 stays the cloud kernel and
# the reboot changes nothing. Name the entry explicitly instead, and undo
# it in phase 2 once the cloud kernel is gone.
[ -f "${GRUB_BAK}" ] || sudo cp "${GRUB_DEFAULTS}" "${GRUB_BAK}"

SUB="$(grep -oP "^submenu '[^']*' \\\$menuentry_id_option '\K[^']*" /boot/grub/grub.cfg | head -1 || true)"
ENT="$(grep -oP "menuentry '[^']*' .*\\\$menuentry_id_option '\K[^']*" /boot/grub/grub.cfg \
    | grep -- "-${ARCH}-advanced" | grep -v -- "-cloud-" | head -1 || true)"
[ -n "${ENT}" ] || die "Could not find a generic menu entry in /boot/grub/grub.cfg. Inspect it by hand."

TARGET="${ENT}"
[ -n "${SUB}" ] && TARGET="${SUB}>${ENT}"
sudo sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"${TARGET}\"|" "${GRUB_DEFAULTS}"
sudo update-grub >/dev/null 2>&1
ok "GRUB_DEFAULT pinned to the generic entry"

# Prove the pin resolves before telling anyone to reboot on it.
#
# Fixed-string search of the whole file, NOT the first `set default=` line:
# grub.cfg carries two of them, and the first is `set default="${next_entry}"`
# inside the one-shot `grub-reboot` branch. Reading that one compares the
# literal text ${next_entry} against the pin and always reports failure.
if grep -qF "set default=\"${TARGET}\"" /boot/grub/grub.cfg; then
    ok "grub.cfg default resolves to the generic entry"
else
    die "grub.cfg did not take the pin — do not reboot; inspect /boot/grub/grub.cfg"
fi

cat <<EOF

================================================================
  Phase 1 done — reboot when it suits you
================================================================

    mpd --vm-restart

(Use that rather than 'sudo reboot': it fires mpd's pre-stop hooks so
databases shut down cleanly first.)

The grub menu still lists the cloud kernel, and its timeout is short but
real — if the generic kernel misbehaves you can pick the old entry from
the hypervisor console, which renders in text mode either way.

Afterwards, re-run this script to finish:

    bash ${BASH_SOURCE[0]}

It will purge the cloud kernel and unpin grub. First boot notes:
'uname -r' should have no '-cloud', and 'ls /dev/dri' should show card0.
EOF
