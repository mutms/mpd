#!/bin/bash
set -euo pipefail
# Hook: graceful mysql shutdown for EventMpdPreStop.
#
# mysql image's PID 1 is mysqld (after the exec chain through
# docker-entrypoint.sh). SIGTERM to PID 1 = graceful shutdown: flush
# buffers, close tables, exit cleanly. The next start skips crash
# recovery.
#
# Fire-and-forget: send the signal, exit immediately. Waiting for
# the daemon to finish would have us SIGKILL'd when the container's
# PID 1 exits.

echo "Sending SIGTERM (graceful shutdown) to mysql..."
kill -TERM 1 2>/dev/null || true
