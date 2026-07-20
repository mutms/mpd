#!/bin/bash
set -euo pipefail
# Ordered 90- so it runs LAST. This hook SIGTERMs PID 1 — the engine
# itself — so the container starts going down the moment it returns.
# Any hook numbered after it fails with exit 255 on a container that
# is already shutting down. Leave 10-89 free for hooks that need a
# live database (dumps, cache flushes, final migrations).
#
# Hook: graceful postgres shutdown for EventMpdPreStop.
#
# postgres image's PID 1 is the postgres server itself (after the
# exec chain through docker-entrypoint.sh + gosu). SIGTERM to PID 1 =
# "smart shutdown": wait for clients to disconnect, flush WAL, exit
# cleanly. The next start skips crash recovery.
#
# We send the signal and exit immediately — if we waited for shutdown
# to finish, the container's PID 1 exit would SIGKILL us mid-wait
# (containers reap all processes on PID 1 exit). The kernel keeps
# postgres running until it finishes its smart shutdown.

echo "Sending SIGTERM (smart shutdown) to postgres..."
kill -TERM 1 2>/dev/null || true
