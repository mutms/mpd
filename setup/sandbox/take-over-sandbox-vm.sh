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
#      Debian's standard task and always present; `curl` is not, so the
#      published recipe uses wget):
#        bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/setup/sandbox/take-over-sandbox-vm.sh)
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
into an mpd sandbox. To do so it intentionally weakens VM security
and reconfigures the host:

  * passwordless sudo for '${USER}'
  * mpd's self-signed CA installed in the system trust store
  * persistent SSH host keys, runtime credentials, generated secrets
  * network stack switched to systemd-resolved fed by NetworkManager
    (a NetworkManager drop-in is written, systemd-resolved is
    apt-installed, /etc/resolv.conf becomes the resolved stub symlink,
    and NetworkManager is restarted). mpd-machine requires resolved
    as the DNS sink; on a brand-new install the NM→resolved DNS push
    occasionally needs a single reboot to take effect, in which case
    the script aborts cleanly and asks you to reboot and re-run.

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
# Vanilla Debian doesn't put the default user in the 'sudo' group (unlike
# Ubuntu), so `sudo` is locked out for ${USER} on a fresh install. The
# root account, however, is unlocked. Bootstrap passwordless sudo by
# `su -c`-ing the sudoers drop-in as root — one prompt for the ROOT
# password, then every later `sudo` call in this script and provision.sh
# runs without any prompt. Idempotent: skipped when sudo -n already works.
if ! sudo -n true 2>/dev/null; then
    echo
    echo "==> Enabling passwordless sudo for ${USER} (you will be prompted once for the root password)"
    su -c "echo '${USER} ALL=(ALL) NOPASSWD:ALL' | install -m 440 /dev/stdin '${SUDOERS_FILE}'"
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
# When invoked via `bash <(curl …)` against an already-cloned repo,
# fast-forward-pull so the user picks up upstream fixes without thinking
# about it. When invoked from inside the cloned repo (running the local
# working copy), we leave the tree alone — that's an explicit "use what
# I checked out" signal.
script_path="$(realpath "${BASH_SOURCE[0]}")"
if [ "$script_path" = "$EXPECTED_SCRIPT" ]; then
    echo
    echo "==> Running from inside cloned repo at ${REPO_DIR} — leaving tree as-is"
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
        echo "==> Repo already cloned at ${REPO_DIR} — pulling latest"
        if ! git -C "$REPO_DIR" pull --ff-only 2>&1 | sed 's/^/    /'; then
            cat >&2 <<EOF

ERROR: git pull --ff-only failed in ${REPO_DIR}.
       Likely causes: local commits diverged from upstream, dirty working
       tree, or no upstream configured. Inspect with:

           git -C ${REPO_DIR} status
           git -C ${REPO_DIR} log --oneline -5

       Resolve (commit/stash/reset), or wipe ${REPO_DIR} entirely to let
       the take-over re-clone, then re-run.
EOF
            exit 1
        fi
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
