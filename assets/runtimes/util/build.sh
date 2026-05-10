#!/bin/bash
# build.sh — util runtime build phase.
#
# Phase 1 (assets/runtime-base/bootstrap.sh) has already created the dev
# user, set up sshd, /etc/mpd identity, /srv/{projects,data,dbs,tools,
# personal} layout, and ~/.bashrc defaults.
#
# util has no language stack on top of runtime-base. Its purpose is to
# host helper / utility project types — cftunnel, future cron-style
# daemons, etc. — that don't fit php/node. This phase only wires up
# tool PATH so project-type tools (e.g. cftunnel-install) are reachable
# inside the container.
#
# Runs as the dev user; uses `sudo` only for individual privileged ops
# (writing /etc/profile.d/* drop-ins). See AGENTS.md §"Mandatory
# privilege rule".

set -euo pipefail

CONTAINER_NAME="$1"

# Runtime-level tools (assets/runtimes/util/tools/) — none ship today;
# project-type tools live one level deeper. Wire the PATH machinery
# anyway so adding a runtime-wide tool later is a no-friction drop-in.
RUNTIME_TOOLS_SRC="/mnt/assets/runtimes/util/tools"
RUNTIME_TOOLS_DST="/srv/tools/util"
if [ -d "$RUNTIME_TOOLS_SRC" ]; then
    mkdir -p "$RUNTIME_TOOLS_DST"
    for SCRIPT in "$RUNTIME_TOOLS_SRC"/*; do
        [ -f "$SCRIPT" ] || continue
        SCRIPT_NAME="$(basename "$SCRIPT")"
        ln -sf "$SCRIPT" "$RUNTIME_TOOLS_DST/$SCRIPT_NAME"
    done
    echo "export PATH=\"${RUNTIME_TOOLS_DST}:\$PATH\"" \
        | sudo tee /etc/profile.d/mpd-tools-runtime.sh >/dev/null
    sudo chmod 644 /etc/profile.d/mpd-tools-runtime.sh
fi

# Project-type tools. Same pattern as the php runtime — scan
# project_types/*/tools, symlink into /srv/tools/<type>/, add to PATH
# via a per-type profile.d drop-in (sourced last, so type tools rank
# highest on PATH and can shadow runtime / base tools).
ASSETS_RT="/mnt/assets/runtimes/util/project_types"
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
    echo "export PATH=\"${TOOLS_DIR}:\$PATH\"" \
        | sudo tee "/etc/profile.d/mpd-tools-type-${TYPE_NAME}.sh" >/dev/null
    sudo chmod 644 "/etc/profile.d/mpd-tools-type-${TYPE_NAME}.sh"
    echo "Installed tools for '${TYPE_NAME}' → ${TOOLS_DIR}"
done

echo "Util runtime '${CONTAINER_NAME}' build complete."
