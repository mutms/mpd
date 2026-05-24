#!/bin/bash
# build.sh — builds the node runtime on top of the runtime base.
#
# Phase-2 of runtime creation. Runs as the dev user (passwordless sudo
# available, used for individual privileged ops only). See AGENTS.md
# §"Mandatory privilege rule".
#
# Phase 1 (assets/runtime-base/bootstrap.sh) has already created the
# dev user, set up sshd, /etc/mpd identity, /srv/{projects,data,dbs,tools}
# layout, and ~/.bashrc defaults.
#
# Installs: Node.js (nvm) + DB client tools. No Apache — TLS termination
# and project routing run in the Caddy frontdoor sidecar attached to the
# pod. Per-project node dev servers run as systemd units listening on TCP
# localhost ports and the sidecar reverse-proxies to them via pod-shared
# netns.
set -euo pipefail

CONTAINER_NAME="$1"

export DEBIAN_FRONTEND=noninteractive

# ── DB client tools (so projects can talk to the shared DB containers) ──────
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
    postgresql-client \
    mariadb-client \
    default-mysql-client

# ── Node.js (nvm) ───────────────────────────────────────────────────────────
bash /opt/mpd/assets/runtime-base/tools/node-install lts

# ── Data directory ──────────────────────────────────────────────────────────
chmod 02777 /srv/data

# ── Tool symlinks + PATH wiring (see ARCHITECTURE.md §7) ────────────────────
RUNTIME_TOOLS_SRC="/opt/mpd/assets/runtimes/node/tools"
RUNTIME_TOOLS_DST="/srv/tools/node"
if [ -d "$RUNTIME_TOOLS_SRC" ]; then
    mkdir -p "$RUNTIME_TOOLS_DST"
    for SCRIPT in "$RUNTIME_TOOLS_SRC"/*; do
        [ -f "$SCRIPT" ] || continue
        SCRIPT_NAME="$(basename "$SCRIPT")"
        ln -sf "$SCRIPT" "$RUNTIME_TOOLS_DST/$SCRIPT_NAME"
    done
    echo "Installed runtime tools → ${RUNTIME_TOOLS_DST}"
fi

# Project-type tools. PATH is set by the dev user's ~/.bashrc (shipped via
# skel) which globs /srv/tools/*/; no /etc/profile.d/ drop-in needed.
ASSETS_RT="/opt/mpd/assets/runtimes/node/project_types"
for TYPE_DIR in "${ASSETS_RT}"/*/tools; do
    [ -d "$TYPE_DIR" ] || continue
    TYPE_NAME="$(basename "$(dirname "$TYPE_DIR")")"
    TOOLS_DIR="/srv/tools/${TYPE_NAME}"
    mkdir -p "$TOOLS_DIR"
    for SCRIPT in "$TYPE_DIR"/*; do
        [ -f "$SCRIPT" ] || continue
        SCRIPT_NAME="$(basename "$SCRIPT")"
        ln -sf "$SCRIPT" "$TOOLS_DIR/$SCRIPT_NAME"
    done
    echo "Installed tools for '${TYPE_NAME}' → ${TOOLS_DIR}"
done

echo "Node runtime '${CONTAINER_NAME}' build complete."
echo "Node (nvm) | no PHP, no Apache (Caddy frontdoor handles HTTPS)"
