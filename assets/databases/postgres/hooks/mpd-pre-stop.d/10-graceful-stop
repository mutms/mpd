#!/bin/bash
set -euo pipefail
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
