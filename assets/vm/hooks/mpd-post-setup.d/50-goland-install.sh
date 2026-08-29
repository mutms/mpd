#!/bin/bash
# Hook: install GoLand on the VM from a seeded tarball.
#
# Fires on mpd-post-setup, VM audience. Does nothing at all unless you
# have put a goland.tgz in your own mpd-virt overlay — see
# `goland-archive-app`, which makes one and prints where to copy it.
#
# The work and every check live in the tool: it no-ops when GoLand is
# already installed and when there is no tarball, which is what makes it
# safe to fire on every `mpd --vm-setup`.
set -euo pipefail

exec /opt/mpd/assets/vm/bin/goland-install-app
