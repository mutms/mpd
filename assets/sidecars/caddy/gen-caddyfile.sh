#!/bin/bash
# gen-caddyfile.sh — render /etc/caddy/Caddyfile from /srv/meta/*/urls.json.
#
# Reads every project's URL list, groups by hostname (so main + behat for the
# same project share one vhost block when their backends match), emits a Caddy
# vhost per group. Backend types supported: php-fpm, reverse-proxy, redirect.
# A pseudo-project `_runtime-<rt>` holds runtime-level URLs published by
# sidecars (e.g. mailpit's canonical `mail.<rt>.mpd.test/`); it lives under
# the same `/srv/meta/*/urls.json` glob and is rendered like any project.
# Stdout is the rendered Caddyfile.
set -euo pipefail

META_DIR="${META_DIR:-/srv/meta}"
HEADER_PATH="${HEADER_PATH:-/opt/sidecar/templates/header.caddyfile}"

if ! command -v jq >/dev/null 2>&1; then
    echo "[mpd-caddy] jq is required by gen-caddyfile.sh — abort." >&2
    exit 1
fi

emit_header() {
    cat "$HEADER_PATH"
    echo
}

# Render one Caddy vhost block.
# Args: project name, comma-joined hostnames, backend JSON (one URL's backend).
# All URLs grouped under the same hostnames are assumed to share a backend
# (configure.sh writes them that way for behat/main pairs).
render_vhost() {
    local project="$1"
    local hosts="$2"
    local backend_json="$3"

    local cert_pem="${META_DIR}/${project}/cert.pem"
    local cert_key="${META_DIR}/${project}/key.pem"

    local btype
    btype=$(jq -r '.type' <<<"$backend_json")

    echo "${hosts} {"
    echo "    import deny_sensitive"
    echo "    tls ${cert_pem} ${cert_key}"

    case "$btype" in
        php-fpm)
            local fastcgi root tryfiles
            fastcgi=$(jq -r '.fastcgi'  <<<"$backend_json")
            root=$(   jq -r '.root'     <<<"$backend_json")
            # tryFiles → space-separated list as-written; default to a sensible
            # fallback when missing.
            tryfiles=$(jq -r '
                if .tryFiles and (.tryFiles | length) > 0
                then .tryFiles | join(" ")
                else "{path} {path}/index.php /index.php"
                end' <<<"$backend_json")
            echo "    root * ${root}"
            echo "    php_fastcgi ${fastcgi} {"
            echo "        try_files ${tryfiles}"
            # Moodle (and a few other PHP apps) hardcode a supported-webserver
            # allowlist that doesn't include Caddy. Spoof Apache to satisfy
            # the check; the actual server is still Caddy.
            echo "        env SERVER_SOFTWARE \"Apache/2.4 (Caddy frontdoor)\""
            echo "    }"
            echo "    file_server"
            ;;
        reverse-proxy)
            local upstream
            upstream=$(jq -r '.upstream' <<<"$backend_json")
            echo "    reverse_proxy ${upstream}"
            ;;
        redirect)
            local target
            target=$(jq -r '.target' <<<"$backend_json")
            echo "    redir ${target} 302"
            ;;
        *)
            echo "    # Unknown backend type '${btype}' — skipping body."
            echo "    respond \"Unsupported backend\" 501"
            ;;
    esac
    echo "}"
    echo
}

# Walk every project. For each, group URLs that share the same backend so
# main + behat (which share an FPM pool) get a single vhost.
emit_header
for meta in "${META_DIR}"/*/urls.json; do
    [ -f "$meta" ] || continue
    project=$(basename "$(dirname "$meta")")

    # Skip projects with no backends (informational URLs only).
    if ! jq -e '[.[] | select(.backend)] | length > 0' "$meta" >/dev/null 2>&1; then
        continue
    fi

    # Group URLs by hash of their backend JSON. URLs with identical backends
    # share a vhost; differing backends get separate ones.
    jq -c '
        [.[] | select(.backend)]
        | group_by(.backend | @json)
        | map({hosts: [.[] | (.url | sub("^https?://"; "") | sub("/$"; "") | sub(":[0-9]+$"; ""))], backend: .[0].backend})
        | .[]
    ' "$meta" | while IFS= read -r group; do
        # group: {hosts: ["a.mpd.test","behat.a.mpd.test"], backend: {...}}
        hosts=$(jq -r '.hosts | join(", ")' <<<"$group")
        backend=$(jq -c '.backend' <<<"$group")
        render_vhost "$project" "$hosts" "$backend"
    done
done
