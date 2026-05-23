#!/bin/bash
# take-over-sandbox-vm.sh — turn a fresh Debian Trixie VM into an mpd sandbox.
#
# This script intentionally weakens VM security (passwordless sudo, mpd's
# self-signed CA in the system trust store, persistent SSH host keys).
# Designed for a wipe-and-rebuild sandbox VM. Do NOT run on a workstation
# or any host with data you would be sad to lose.
#
# All actual provisioning lives in bootstrap/ (the same scripts mpd-virt
# uses for managed VMs). This wrapper just:
#   - shows the disclaimer,
#   - runs bootstrap/10-passwordless-sudo.sh (root password prompt),
#   - runs bootstrap/20-git-clone.sh (clones the repo to ~/Developer/mpd),
#   - chains to setup/sandbox/lib/provision.sh which runs the remaining
#     bootstrap steps + sandbox-specific finalize (VS Code, GNOME launcher,
#     mpd --setup, pre-warm).
#
# Two valid invocation modes:
#   1. Standalone (wget|bash flow, no separate clone step):
#        bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/setup/sandbox/take-over-sandbox-vm.sh)
#      Downloads bootstrap/10 + bootstrap/20 via wget, runs them, then
#      execs the cloned lib/provision.sh.
#   2. In-repo (when the mpd repo is already cloned):
#        bash ~/Developer/mpd/setup/sandbox/take-over-sandbox-vm.sh
#      Uses the local bootstrap/* scripts directly.
#
# Idempotent — safe to re-run after a partial failure.

set -euo pipefail

# --- Disclaimer ---------------------------------------------------------
# Everything below is gated by bootstrap/10-passwordless-sudo.sh
# (hostname must be mpd-sandbox or mpd-000; OS must be Debian Trixie).
# Show the disclaimer first so the user knows what they're consenting to
# before bootstrap/10 prompts for the root password.

cat <<'EOF'

================================================================
  TAKE OVER VM
================================================================

This script is about to turn this VM into an mpd sandbox. To do so
it intentionally weakens VM security and reconfigures the host:

  * passwordless sudo for the current user
  * mpd's self-signed CA installed in the system trust store
  * persistent SSH host keys, runtime credentials, generated secrets
  * network stack switched to systemd-resolved fed by NetworkManager
  * hostname normalised to mpd-000 if it isn't already

This is appropriate ONLY for a sandbox VM you can wipe and rebuild.
Never run this on a workstation, on a shared host, or on a VM with
any data you would be sad to lose.

NO WARRANTY. If this script breaks your VM, your only remedy is to
revert to the hypervisor snapshot you took BEFORE running it. If
you have not taken a snapshot, abort now (Ctrl-C) and do so first.

================================================================
EOF

read -r -p "Press Enter to proceed (Ctrl-C to abort): " _

# --- Locate the bootstrap scripts -------------------------------------
# If take-over was invoked from inside the cloned repo, use the local
# bootstrap/ files. If it was invoked via wget|bash, the repo isn't
# cloned yet — wget bootstrap/10 + bootstrap/20 to /tmp first.

REPO_DIR="${HOME}/Developer/mpd"
MPD_BRANCH="${MPD_BRANCH:-main}"
MPD_REPO_RAW="https://raw.githubusercontent.com/mutms/mpd/${MPD_BRANCH}"

script_path="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
if [ -f "${REPO_DIR}/setup/sandbox/take-over-sandbox-vm.sh" ] \
   && [ "${script_path}" = "$(realpath "${REPO_DIR}/setup/sandbox/take-over-sandbox-vm.sh")" ]; then
    # Running from inside the cloned repo — use local files.
    BOOT10="${REPO_DIR}/bootstrap/10-passwordless-sudo.sh"
    BOOT20="${REPO_DIR}/bootstrap/20-git-clone.sh"
else
    # Running via wget|bash — fetch the two wgettable bootstrap scripts.
    TMPDIR_BOOT=$(mktemp -d)
    trap 'rm -rf "$TMPDIR_BOOT"' EXIT
    wget -qO "${TMPDIR_BOOT}/10-passwordless-sudo.sh" "${MPD_REPO_RAW}/bootstrap/10-passwordless-sudo.sh"
    wget -qO "${TMPDIR_BOOT}/20-git-clone.sh"         "${MPD_REPO_RAW}/bootstrap/20-git-clone.sh"
    BOOT10="${TMPDIR_BOOT}/10-passwordless-sudo.sh"
    BOOT20="${TMPDIR_BOOT}/20-git-clone.sh"
fi

# --- Run the wgettable bootstrap steps --------------------------------
# Step 10 prompts for the root password ONCE (interactively) to write
# the sudoers drop-in. Step 20 apt-installs git and clones the repo.

bash "${BOOT10}"
bash "${BOOT20}"

# At this point ~/Developer/mpd is a clean git checkout. Chain to the
# sandbox-specific finalizer, which runs bootstrap/30..60 + the
# GNOME-VM-only extras (VS Code, launcher, mpd --setup, pre-warm).
exec bash "${REPO_DIR}/setup/sandbox/lib/provision.sh"
