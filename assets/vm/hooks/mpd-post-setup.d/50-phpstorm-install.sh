#!/bin/bash
# Hook: install the PhpStorm backend from a seeded tarball.
#
# Fires on mpd-post-setup, VM audience. Does nothing at all unless
# you have put a phpstorm.tgz in your own mpd-virt overlay — see
# `phpstorm-archive-app`, which makes one and prints where to copy it.
#
# The work and every check live in the tool: it no-ops when PhpStorm is
# already installed and when there is no tarball, which is what makes it
# safe to fire on every `mpd --vm-setup`. Worth firing there: the
# home is new on a freshly created VM, and the next
# setup puts the backend back without a download.
set -euo pipefail

exec /opt/mpd/assets/vm/bin/phpstorm-install-app
