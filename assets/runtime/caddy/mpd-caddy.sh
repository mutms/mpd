#!/bin/bash
# mpd-caddy.sh — the in-runtime TLS frontdoor, run by mpd-caddy.service
# as the dev user (the only identity that can read the 0600 project keys
# under /srv/meta/). Renders the Caddyfile, starts caddy, and
# rebuilds-and-reloads on changes inside /srv/meta/.
set -euo pipefail

CADDYFILE="${CADDYFILE:-/run/mpd-caddy/Caddyfile}"
META_DIR="${META_DIR:-/srv/meta}"
GEN="${GEN:-/opt/mpd/assets/runtime/caddy/gen-caddyfile.sh}"

regenerate() {
    "$GEN" > "${CADDYFILE}.new"
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

# The initial render must succeed for first start. Later reload failures
# are logged and the previous Caddyfile keeps serving.
mkdir -p "$(dirname "$CADDYFILE")"
regenerate

caddy run --config "${CADDYFILE}" --adapter caddyfile --watch &
CADDY_PID=$!

# Watcher: rebuild on any change inside /srv/meta/.
mkdir -p "$META_DIR"
inotifywait -m -r -e close_write,delete,moved_to,moved_from "$META_DIR" 2>/dev/null \
    | while read -r path event file; do
        # Coalesce bursts: a project create touches several files.
        sleep 0.5
        if regenerate; then
            # --force matters: a certificate rotation rewrites cert.pem but
            # not the Caddyfile, so `--watch` sees no change and caddy keeps
            # serving the superseded cert from memory. On a real config
            # change this is only a second, graceful reload.
            caddy reload --config "${CADDYFILE}" --adapter caddyfile --force \
                >/dev/null 2>&1 || true
        fi
    done &

# Keep the service alive on caddy.
wait "$CADDY_PID"
