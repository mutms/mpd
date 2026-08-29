#!/bin/bash
# Hook: install GoLand on the VM from a seeded tarball (see
# `goland-archive-app`). Fires on mpd-post-setup, VM audience —
# docs/hooks.md. The tool no-ops without a tarball or with GoLand
# installed, so firing on every `mpd --vm-setup` is safe.
set -euo pipefail

exec /opt/mpd/assets/vm/bin/goland-install-app
