#!/bin/bash
set -euo pipefail
# Ordered 90- so it runs LAST. This hook SIGTERMs PID 1 — the engine
# itself — so the container starts going down the moment it returns.
# Any hook numbered after it fails with exit 255 on a container that
# is already shutting down. Leave 10-89 free for hooks that need a
# live database (dumps, cache flushes, final migrations).
#
# Hook: graceful mariadb shutdown for EventMpdPreStop.
#
# mariadb image's PID 1 is mariadbd (after the exec chain through
# docker-entrypoint.sh). SIGTERM to PID 1 = graceful shutdown: flush
# buffers, close tables, exit cleanly. The next start skips crash
# recovery.
#
# Fire-and-forget: send the signal, exit immediately. Waiting for
# the daemon to finish would have us SIGKILL'd when the container's
# PID 1 exits.

echo "Sending SIGTERM (graceful shutdown) to mariadb..."
kill -TERM 1 2>/dev/null || true
