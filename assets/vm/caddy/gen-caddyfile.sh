#!/bin/bash
# gen-caddyfile.sh — render the frontdoor Caddyfile from /srv/meta/*/urls.json
# to stdout. URLs with matching backends share one vhost block. Backend
# types: php-fpm, reverse-proxy, redirect. URLs without a backend are
# informational and skipped.
set -euo pipefail

META_DIR="${META_DIR:-/srv/meta}"
HEADER_PATH="${HEADER_PATH:-/opt/mpd/assets/vm/caddy/templates/header.caddyfile}"

if ! command -v jq >/dev/null 2>&1; then
    echo "[mpd-caddy] jq is required by gen-caddyfile.sh — abort." >&2
    exit 1
fi

emit_header() {
    cat "$HEADER_PATH"
    echo
}

# render_vhost <project> <comma-joined hostnames> <backend JSON> — emit one
# Caddy vhost block. Grouped hostnames share one backend by construction.
render_vhost() {
    local project="$1"
    local hosts="$2"
    local backend_json="$3"

    local cert_pem="${META_DIR}/${project}/cert.pem"
    local cert_key="${META_DIR}/${project}/key.pem"

    local btype
    btype=$(jq -r '.type' <<<"$backend_json")

    echo "${hosts} {"
    if [ -n "${MPD_CADDY_BIND:-}" ]; then
        echo "    bind ${MPD_CADDY_BIND}"
    fi
    echo "    import deny_sensitive"
    echo "    tls ${cert_pem} ${cert_key}"

    case "$btype" in
        php-fpm)
            local fastcgi root tryfiles
            fastcgi=$(jq -r '.fastcgi'  <<<"$backend_json")
            root=$(   jq -r '.root'     <<<"$backend_json")
            tryfiles=$(jq -r '
                if .tryFiles and (.tryFiles | length) > 0
                then .tryFiles | join(" ")
                else "{path} {path}/index.php /index.php"
                end' <<<"$backend_json")
            echo "    root * ${root}"
            echo "    php_fastcgi ${fastcgi} {"
            echo "        try_files ${tryfiles}"
            # Moodle's supported-webserver check does not know Caddy;
            # spoof Apache to satisfy it.
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

emit_header
for meta in "${META_DIR}"/*/urls.json; do
    [ -f "$meta" ] || continue
    project=$(basename "$(dirname "$meta")")

    # Skip projects with informational URLs only.
    if ! jq -e '[.[] | select(.backend)] | length > 0' "$meta" >/dev/null 2>&1; then
        continue
    fi

    # URLs with identical backends share a vhost (main + behat pairs).
    jq -c '
        [.[] | select(.backend)]
        | group_by(.backend | @json)
        | map({hosts: [.[] | (.url | sub("^https?://"; "") | sub("/$"; "") | sub(":[0-9]+$"; ""))], backend: .[0].backend})
        | .[]
    ' "$meta" | while IFS= read -r group; do
        hosts=$(jq -r '.hosts | join(", ")' <<<"$group")
        backend=$(jq -c '.backend' <<<"$group")
        render_vhost "$project" "$hosts" "$backend"
    done
done
