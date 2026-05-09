#!/bin/bash
# take-over-sandbox-vm.sh — turn a fresh Ubuntu 26.04 VM into an mpd sandbox.
#
# This script intentionally weakens VM security (passwordless sudo, mpd's
# self-signed CA in the system trust store, persistent SSH host keys).
# Designed for a wipe-and-rebuild sandbox VM. Do NOT run on a workstation
# or any host with data you would be sad to lose.
#
# Two valid invocation modes:
#   1. Standalone (curl|bash flow, no separate clone step):
#        bash <(curl -sSL https://raw.githubusercontent.com/mutms/mpd/main/setup/sandbox/take-over-sandbox-vm.sh)
#      Self-bootstraps: apt-installs git, clones mpd to ~/Developer/mpd/,
#      then exec's lib/provision.sh from the cloned tree.
#   2. In-repo (when the mpd repo is already cloned):
#        bash ~/Developer/mpd/setup/sandbox/take-over-sandbox-vm.sh
#      Skips the clone, exec's the sibling lib/provision.sh.
#
# Idempotent — safe to re-run after a partial failure.

set -euo pipefail

REQUIRED_HOSTNAME="mpd-machine-sandbox"
REPO_URL="https://github.com/mutms/mpd.git"
REPO_DIR="$HOME/Developer/mpd"
SUDOERS_FILE="/etc/sudoers.d/mpd-${USER}"
EXPECTED_SCRIPT="${REPO_DIR}/setup/sandbox/take-over-sandbox-vm.sh"
PROVISION_SCRIPT="${REPO_DIR}/setup/sandbox/lib/provision.sh"

# --- Hostname gate ------------------------------------------------------
# Primary safety mechanism: the act of renaming a VM to
# 'mpd-machine-sandbox' is the deliberate consent that you intend this VM
# to be sacrificed to mpd's sandbox configuration. Stronger than a typed
# confirmation word — renaming is conscious work, not a reflex keypress.
current_hostname="$(hostname)"
if [ "$current_hostname" != "$REQUIRED_HOSTNAME" ]; then
    cat >&2 <<EOF

ERROR: This script requires hostname '${REQUIRED_HOSTNAME}'.
       Current hostname is '${current_hostname}'.

The hostname check is the safety gate — every shell prompt on this VM
will read 'user@${REQUIRED_HOSTNAME}', a permanent reminder that this
host is mpd's sandbox and not your workstation.

To rename and continue:

    sudo hostnamectl set-hostname ${REQUIRED_HOSTNAME}
    sudo sed -i 's/^127\\.0\\.1\\.1.*/127.0.1.1\\t${REQUIRED_HOSTNAME}/' /etc/hosts

Then log out and log back in (so your shell prompt picks up the new
name), and re-run this script.
EOF
    exit 1
fi

# --- OS gate ------------------------------------------------------------
if [ ! -r /etc/os-release ]; then
    echo "ERROR: /etc/os-release missing — cannot verify OS." >&2
    exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
if [ "${ID:-}" != "ubuntu" ] || [ "${VERSION_ID:-}" != "26.04" ]; then
    cat >&2 <<EOF
ERROR: This script targets Ubuntu 26.04 LTS.
       Detected: ${ID:-unknown}/${VERSION_ID:-unknown}
EOF
    exit 1
fi

# --- Disclaimer ---------------------------------------------------------
cat <<EOF

================================================================
  TAKE OVER VM: ${current_hostname}
================================================================

This script is about to take over '${current_hostname}' and turn it
into an mpd sandbox. To do so it intentionally weakens VM security:

  * passwordless sudo for '${USER}'
  * mpd's self-signed CA installed in the system trust store
  * persistent SSH host keys, runtime credentials, generated secrets

This is appropriate ONLY for a sandbox VM you can wipe and rebuild.
Never run this on a workstation, on a shared host, or on a VM with
any data you would be sad to lose.

NO WARRANTY. If this script breaks your VM, your only remedy is to
revert to the hypervisor snapshot you took BEFORE running it. If
you have not taken a snapshot, abort now (Ctrl-C) and do so first.

================================================================
EOF

read -r -p "Press Enter to proceed (Ctrl-C to abort): " _

# --- Enable passwordless sudo ------------------------------------------
# One-time: sudo will prompt for a password the first time. Subsequent
# invocations in this script and in lib/provision.sh use passwordless sudo.
if ! sudo -n true 2>/dev/null; then
    echo
    echo "==> Enabling passwordless sudo for ${USER} (you will be prompted once for your password)"
    echo "${USER} ALL=(ALL) NOPASSWD:ALL" \
        | sudo install -m 440 /dev/stdin "${SUDOERS_FILE}"
    echo "    Wrote ${SUDOERS_FILE}"
else
    echo
    echo "==> Passwordless sudo already enabled — skipping"
fi

# --- Install git --------------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
    echo
    echo "==> Installing git via apt"
    sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git
fi

# --- Detect self-location: in-repo vs standalone -----------------------
script_path="$(realpath "${BASH_SOURCE[0]}")"
if [ "$script_path" = "$EXPECTED_SCRIPT" ]; then
    echo
    echo "==> Running from inside cloned repo at ${REPO_DIR} — skipping clone"
else
    if [ -d "$REPO_DIR" ] && [ ! -d "$REPO_DIR/.git" ]; then
        cat >&2 <<EOF
ERROR: ${REPO_DIR} exists but is not a git checkout. Refusing to clobber.
       Move or delete it, then re-run.
EOF
        exit 1
    fi
    if [ ! -d "$REPO_DIR/.git" ]; then
        echo
        echo "==> Cloning mpd repo to ${REPO_DIR}"
        mkdir -p "$(dirname "$REPO_DIR")"
        git clone "$REPO_URL" "$REPO_DIR"
    else
        echo
        echo "==> Repo already cloned at ${REPO_DIR} — using as-is"
    fi
fi

# --- Hand off -----------------------------------------------------------
if [ ! -f "$PROVISION_SCRIPT" ]; then
    echo "ERROR: provision script not found at ${PROVISION_SCRIPT}" >&2
    exit 1
fi
echo
echo "==> Handing off to ${PROVISION_SCRIPT}"
echo
exec bash "$PROVISION_SCRIPT"
