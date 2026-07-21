#!/bin/bash
# build.sh — util runtime build phase.
#
# Phase 1 (assets/runtime-base/bootstrap.sh) has already created the dev
# user, set up sshd, /etc/mpd identity, /srv/{projects,data,dbs,tools}
# layout, and ~/.bashrc defaults.
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

echo "Util runtime '${CONTAINER_NAME}' build complete."
