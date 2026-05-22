#!/bin/bash
# take-over-sandbox-vm.sh — turn a fresh Debian Trixie VM into an mpd sandbox.
#
# This script intentionally weakens VM security (passwordless sudo, mpd's
# self-signed CA in the system trust store, persistent SSH host keys).
# Designed for a wipe-and-rebuild sandbox VM. Do NOT run on a workstation
# or any host with data you would be sad to lose.
#
# Two valid invocation modes:
#   1. Standalone (wget|bash flow, no separate clone step — `wget` is in
#      Debian's standard task and always present; `curl` is not):
#        bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/setup/sandbox/take-over-sandbox-vm.sh)
#      Self-bootstraps: enables passwordless sudo, apt-installs git,
#      clones mpd to ~/Developer/mpd/, then exec's lib/provision.sh.
#   2. In-repo (when the mpd repo is already cloned):
#        bash ~/Developer/mpd/setup/sandbox/take-over-sandbox-vm.sh
#
# Idempotent — safe to re-run after a partial failure.

set -euo pipefail

REPO_URL="https://github.com/mutms/mpd.git"
REPO_DIR="$HOME/Developer/mpd"
SUDOERS_FILE="/etc/sudoers.d/00-mpd-${USER}"
EXPECTED_SCRIPT="${REPO_DIR}/setup/sandbox/take-over-sandbox-vm.sh"
PROVISION_SCRIPT="${REPO_DIR}/setup/sandbox/lib/provision.sh"

# --- Hostname gate ------------------------------------------------------
# Primary safety mechanism: the act of renaming a fresh VM to one of these
# names is the deliberate consent that you intend this VM to be sacrificed
# to mpd's sandbox configuration. Stronger than a typed confirmation word.
#
#   mpd-sandbox — the user-friendly name we tell Debian-installer users
#                 to type. bootstrap/20-networking.sh renames it to mpd-000
#                 on first take-over.
#   mpd-000     — the canonical name after the first take-over completed.
#                 Accepting it here keeps the script idempotent on re-runs.
current_hostname="$(hostname -s)"
case "$current_hostname" in
    mpd-sandbox|mpd-000) ;;
    *)
        cat >&2 <<EOF

ERROR: This script requires hostname 'mpd-sandbox' (first take-over) or
       'mpd-000' (re-run after a previous take-over).
       Current hostname is '${current_hostname}'.

The hostname gate is the safety mechanism — every shell prompt on this VM
should read 'user@mpd-000', a permanent reminder that this host is mpd's
sandbox and not your workstation.

To rename and continue:

    sudo hostnamectl set-hostname mpd-sandbox
    sudo sed -i 's/^127\\.0\\.1\\.1.*/127.0.1.1\\tmpd-sandbox/' /etc/hosts

Then log out and log back in (so your shell prompt picks up the new
name), and re-run this script.
EOF
        exit 1
        ;;
esac

# --- OS gate ------------------------------------------------------------
if [ ! -r /etc/os-release ]; then
    echo "ERROR: /etc/os-release missing — cannot verify OS." >&2
    exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
if [ "${ID:-}" != "debian" ] || [ "${VERSION_CODENAME:-}" != "trixie" ]; then
    cat >&2 <<EOF
ERROR: This script targets Debian Trixie (13).
       Detected: ${ID:-unknown}/${VERSION_CODENAME:-unknown}
EOF
    exit 1
fi

# --- Disclaimer ---------------------------------------------------------
cat <<EOF

================================================================
  TAKE OVER VM: ${current_hostname}
================================================================

This script is about to take over '${current_hostname}' and turn it
into an mpd sandbox VM. To do so it intentionally weakens VM security
and reconfigures the host:

  * passwordless sudo for '${USER}'
  * mpd's self-signed CA installed in the system trust store
  * persistent SSH host keys, runtime credentials, generated secrets
  * network stack switched to systemd-resolved fed by NetworkManager
  * hostname renamed from mpd-sandbox to mpd-000 if needed

This is appropriate ONLY for a sandbox VM you can wipe and rebuild.
Never run this on a workstation, on a shared host, or on a VM with
any data you would be sad to lose.

NO WARRANTY. If this script breaks your VM, your only remedy is to
revert to the hypervisor snapshot you took BEFORE running it. If
you have not taken a snapshot, abort now (Ctrl-C) and do so first.

================================================================
EOF

read -r -p "Press Enter to proceed (Ctrl-C to abort): " _

# --- Enable passwordless sudo (pre-bootstrap) --------------------------
# We can't call bootstrap/10-passwordless-sudo.sh yet — the repo isn't
# cloned. Replicate its `su -c` shape inline so we can install git and
# clone the repo. bootstrap step 10 is a silent no-op once we get there.
if ! sudo -n true 2>/dev/null; then
    echo
    echo "==> Enabling passwordless sudo for ${USER} (you will be prompted once for the root password)"
    su -c "echo '${USER} ALL=(ALL) NOPASSWD:ALL' | install -m 440 /dev/stdin '${SUDOERS_FILE}'"
    echo "    Wrote ${SUDOERS_FILE}"
fi

# --- Install git --------------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
    echo
    echo "==> Installing git via apt"
    sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git
fi

# --- Clone or pull the mpd repo ---------------------------------------
# wget|bash invocation: clone if absent, ff-pull if present. In-repo
# invocation: leave the checkout alone (explicit "use what I have").
script_path="$(realpath "${BASH_SOURCE[0]}")"
if [ "$script_path" = "$EXPECTED_SCRIPT" ]; then
    echo
    echo "==> Running from inside cloned repo at ${REPO_DIR} — leaving tree as-is"
else
    if [ -d "$REPO_DIR" ] && [ ! -d "$REPO_DIR/.git" ]; then
        echo "ERROR: ${REPO_DIR} exists but is not a git checkout. Move or delete it, then re-run." >&2
        exit 1
    fi
    if [ ! -d "$REPO_DIR/.git" ]; then
        echo
        echo "==> Cloning mpd repo to ${REPO_DIR}"
        mkdir -p "$(dirname "$REPO_DIR")"
        git clone "$REPO_URL" "$REPO_DIR"
    else
        echo
        echo "==> Repo at ${REPO_DIR} already cloned — pulling latest"
        if ! git -C "$REPO_DIR" pull --ff-only 2>&1 | sed 's/^/    /'; then
            echo "ERROR: git pull --ff-only failed in ${REPO_DIR}. Resolve and re-run." >&2
            exit 1
        fi
    fi
fi

# --- Hand off to lib/provision.sh -------------------------------------
[ -f "$PROVISION_SCRIPT" ] || { echo "ERROR: ${PROVISION_SCRIPT} missing." >&2; exit 1; }
echo
echo "==> Handing off to ${PROVISION_SCRIPT}"
echo
exec bash "$PROVISION_SCRIPT"
