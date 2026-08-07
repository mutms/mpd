#!/bin/bash
# mpd-caddy.sh — the in-runtime TLS frontdoor, run by mpd-caddy.service
# as the dev user (the only identity that can read the 0600 project keys
# under /srv/meta/<project>/).
#
# Generates the Caddyfile from /srv/meta/*/urls.json, starts caddy (the
# apt-installed binary), and rebuilds-and-reloads on changes inside
# /srv/meta/. Successor of the retired caddy frontdoor sidecar's entry.sh.
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

# Initial render must succeed for first start; after that, reload failures are
# logged and the previous Caddyfile keeps serving traffic.
mkdir -p "$(dirname "$CADDYFILE")"
regenerate

# Start caddy in the background. `--watch` makes it reload automatically when
# the Caddyfile on disk changes.
caddy run --config "${CADDYFILE}" --adapter caddyfile --watch &
CADDY_PID=$!

# Watcher: rebuild on any change inside /srv/meta/.
mkdir -p "$META_DIR"
inotifywait -m -r -e close_write,delete,moved_to,moved_from "$META_DIR" 2>/dev/null \
    | while read -r path event file; do
        # Coalesce bursts: wait briefly so a project-create that touches
        # several files doesn't fire one regenerate per file.
        sleep 0.5
        # Drain any pending events without blocking forever.
        if regenerate; then
            # --force is the point of this call. A certificate rotation
            # rewrites cert.pem but not the Caddyfile, which only ever
            # names its path — so the regenerated config is byte-identical,
            # `caddy --watch` compares the two, finds no difference, and
            # does not reload. Caddy then serves the superseded
            # certificate from memory until something restarts the
            # service. After a CA rotation that certificate is signed by
            # a CA nothing trusts any more, so every project URL fails TLS
            # while both the config and the files on disk look correct.
            #
            # When the config genuinely did change, --watch reloads as
            # well and this is a second, graceful reload of identical
            # content: milliseconds, and only on a real change.
            caddy reload --config "${CADDYFILE}" --adapter caddyfile --force \
                >/dev/null 2>&1 || true
        fi
    done &

# Keep the service alive on caddy.
wait "$CADDY_PID"
