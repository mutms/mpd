#!/bin/bash
# bootstrap/99-update.sh
#
# Refresh a running mpd VM to current `main`. Runs *after* initial
# bootstrap has completed (i.e. the VM is already provisioned and the
# `mpd` binary is on PATH). Invoked by `mpd-virt update <NNN>` over
# SSH, but also fine to run by hand:
#
#     bash /opt/mpd/bootstrap/99-update.sh
#
# The contract for mpd-virt is "run this script, you'll be up to date".
# Anything we ever need to add to the update flow — extra migrations,
# new packages, container-image rebuilds, mpd schema changes — goes
# here without mpd-virt needing a release.
#
# Idempotent: every step is a no-op when there's nothing to do.
#
# ── Self-modification caveat ───────────────────────────────────────────
# When this script changes ITS OWN structure (adds a new step, reorders
# them) one update cycle is not enough:
#
#   - bash reads 99-update.sh once when it starts. The git pull replaces
#     it on disk, but the running process keeps executing the old
#     in-memory copy.
#   - Every command invoked AFTER the pull (`bash 50-build.sh`,
#     `mpd --vm-setup`, …) is read fresh from disk and runs the NEW
#     version — so changes to those propagate in a single run.
#   - But the orchestration in 70 itself (what to call, in what order)
#     is whatever the originally-loaded copy said. A new step added
#     inside 70 will only execute on the SECOND `mpd-virt update`.
#
# Worst case: run update twice when a release reshuffles 99-update.sh
# itself. If a release ever needs a one-shot migration that MUST run in
# the same cycle as its code change, drop in the standard self-reexec
# pattern right after the git pull:
#
#     if [ -z "${MPD_UPDATE_REEXECED:-}" ]; then
#         export MPD_UPDATE_REEXECED=1
#         exec bash "${BASH_SOURCE[0]}"
#     fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/00-common.sh"

REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- Pull latest source --------------------------------------------------
# Reuse 20-git-clone.sh: it handles "clone-or-fast-forward" with the same
# safety rails (refuses on dirty tree, etc.).

step "Updating mpd source"
bash "${SCRIPT_DIR}/20-git-clone.sh"

# --- Rebuild + ensure PATH ----------------------------------------------
# 50-build.sh runs `make install` (fast no-op when unchanged) and
# re-asserts ~/.bashrc PATH + /usr/local symlink hygiene.

step "Rebuilding mpd binary"
bash "${SCRIPT_DIR}/50-build.sh"

# --- Re-run mpd --vm-setup --------------------------------------------------
# Picks up any in-mpd setup deltas: new services, new dnsmasq records,
# updated container images, refreshed certificates. Idempotent.

step "Re-running mpd --vm-setup"
mpd --vm-setup

ok "Update complete."
