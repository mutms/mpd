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

# render_vhost <project> <comma-joined hostnames> <backend JSON> <agent 0|1>
# — emit one Caddy vhost block. Grouped hostnames share one backend by
# construction. agent=0 leaves out the backend's agent route.
render_vhost() {
    local project="$1"
    local hosts="$2"
    local backend_json="$3"
    local allow_agent="${4:-1}"

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
            # Optional agent route: scripts that ship with mpd, served under
            # a reserved prefix next to the project's own webroot. The root
            # is mpd code, never a directory a project can write to. Each
            # script checks a single-use token, see the project type's
            # agent/lib.php. A request it does not answer gets 404 rather
            # than falling through to the project.
            local agent_prefix agent_root
            agent_prefix=$(jq -r '.agent.prefix // empty' <<<"$backend_json")
            agent_root=$(  jq -r '.agent.root // empty'   <<<"$backend_json")
            if [ "$allow_agent" = "1" ] && [ -n "$agent_prefix" ] && [ -n "$agent_root" ]; then
                echo "    handle ${agent_prefix}/* {"
                echo "        root * ${agent_root}"
                echo "        route {"
                echo "            php_fastcgi ${fastcgi} {"
                echo "                try_files {path}"
                echo "                env MPD_PROJECT \"${project}\""
                jq -r '.agent.env // {} | to_entries[]
                    | "                env \(.key) \"\(.value)\""' <<<"$backend_json"
                echo "            }"
                echo "            respond 404"
                echo "        }"
                echo "    }"
            fi
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
            local upstream h2c
            upstream=$(jq -r '.upstream' <<<"$backend_json")
            # h2c: reach a gRPC/HTTP2-only backend (Zitadel) over cleartext HTTP/2.
            h2c=$(jq -r '.h2c // false' <<<"$backend_json")
            if [ "$h2c" = "true" ]; then
                echo "    reverse_proxy h2c://${upstream}"
            else
                echo "    reverse_proxy ${upstream}"
            fi
            ;;
        static)
            # A site that is only files: caddy serves them where they are,
            # so nothing has to be built, started or kept running.
            #
            # browse lists a directory that has no index.html, the way a
            # local test server is expected to. These VMs answer only to
            # their own developer, and the deny_sensitive rules above still
            # refuse the files that matter.
            local root
            root=$(jq -r '.root' <<<"$backend_json")
            echo "    root * ${root}"
            echo "    file_server browse"
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

    # An active Cloudflare quick tunnel (trycloudflare-start) adds its
    # public host to this project's php-fpm vhost, so caddy routes the
    # forwarded requests. cloudflared connects with the in-zone SNI, so
    # the project cert stays valid.
    tunnel_host=""
    if [ -f "${META_DIR}/${project}/tunnel.json" ]; then
        tunnel_host=$(jq -r '.host // empty' "${META_DIR}/${project}/tunnel.json" 2>/dev/null || true)
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
        agent=1
        if [ -n "$tunnel_host" ] && [ "$(jq -r '.type' <<<"$backend")" = "php-fpm" ]; then
            hosts="${hosts}, ${tunnel_host}"
            # The tunnel makes this vhost reachable from the internet, so
            # the agent route goes away for as long as the tunnel is up.
            agent=0
        fi
        render_vhost "$project" "$hosts" "$backend" "$agent"
    done
done
