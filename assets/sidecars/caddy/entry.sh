#!/bin/bash
# entry.sh — sidecar entry point.
# Generates the Caddyfile from /srv/meta/*/urls.json, starts Caddy, and
# rebuilds-and-reloads on changes inside /srv/meta/.
set -euo pipefail

CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
META_DIR="${META_DIR:-/srv/meta}"

regenerate() {
    /opt/mpd/gen-caddyfile.sh > "${CADDYFILE}.new"
    if ! caddy validate --config "${CADDYFILE}.new" --adapter caddyfile >/dev/null 2>&1; then
        echo "[mpd-caddy] generated Caddyfile failed validation; not reloading" >&2
        echo "--- generated Caddyfile (rejected) ---" >&2
        cat "${CADDYFILE}.new" >&2
        echo "--- end ---" >&2
        rm -f "${CADDYFILE}.new"
        return 1
    fi
    mv "${CADDYFILE}.new" "${CADDYFILE}"
}

# Initial render must succeed for first start; after that, reload failures are
# logged and the previous Caddyfile keeps serving traffic.
regenerate

# Start Caddy in the background. `--watch` makes it reload automatically when
# the Caddyfile on disk changes.
caddy run --config "${CADDYFILE}" --adapter caddyfile --watch &
CADDY_PID=$!

# Watcher: rebuild on any change inside /srv/meta/. When `caddy --watch` sees
# the Caddyfile timestamp change it reloads automatically — no SIGHUP needed.
mkdir -p "$META_DIR"
inotifywait -m -r -e close_write,delete,moved_to,moved_from "$META_DIR" 2>/dev/null \
    | while read -r path event file; do
        # Coalesce bursts: wait briefly so a project-create that touches
        # several files doesn't fire one regenerate per file.
        sleep 0.5
        # Drain any pending events without blocking forever.
        regenerate || true
    done &

# Keep the container alive on Caddy.
wait "$CADDY_PID"
