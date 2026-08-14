#!/bin/bash
# configure.sh <project-name>
# Idempotent project repair/configuration for Astro:
#   - fixes ownership of /srv/projects/<project>
#   - ensures dependencies exist
set -euo pipefail

# shellcheck source=/dev/null
source /opt/mpd/assets/runtime/lib/nvm-env.sh

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"

if [ ! -d "$PROJECT_DIR" ]; then
    echo "Error: ${PROJECT_DIR} does not exist — run mpd ${PROJECT_NAME} create first" >&2
    exit 1
fi

if [ ! -f "${PROJECT_DIR}/package.json" ]; then
    echo "Error: ${PROJECT_DIR}/package.json not found — is this an Astro/Node project?" >&2
    exit 1
fi

# /srv/meta/<project>/ holds urls.json + effective.json plus
# cert.pem/key.pem/project.json that mpd writes from the VM (which
# runs as the dev uid). /srv/meta is dev-owned, so plain mkdir works.
mkdir -p "/srv/meta/${PROJECT_NAME}"

# Per-project mpd.env was seeded by project-create.sh at create time;
# do not re-stage here. Layered resolution: /var/lib/mpd/env/mpd-vm.env first,
# then per-project mpd.env.
# shellcheck source=/dev/null
source /opt/mpd/assets/runtime/lib/source-mpd-env.sh

cd "${PROJECT_DIR}"

if [ -f ".nvmrc" ]; then
    nvm install
fi

# Keep configure idempotent and lightweight: install deps only when missing.
if [ ! -d "${PROJECT_DIR}/node_modules" ]; then
    echo "node_modules missing — running npm install..."
    npm install
else
    echo "node_modules already present — skipping npm install."
fi

# Resolve the dev-server port from astro.config.mjs, defaulting to Astro's
# own 4321.
#
# astro.config.mjs is the ONLY source, deliberately. mpd no longer starts
# the dev server, so an mpd-side port setting could only move caddy's
# upstream — the server would keep binding whatever its own config says,
# and the mismatch would surface as a 502 with nothing obviously wrong.
# One knob that both sides already read beats two that can disagree.
#
# Two astro projects in one runtime therefore need different server.port
# values in their own configs; the second to start otherwise fails to
# bind. (There used to be an MPD_NODE_ASTRO_PORT override here, from when
# mpd ran the server and could pass --port itself.)
PORT="4321"
if [ -f "${PROJECT_DIR}/astro.config.mjs" ]; then
    DETECTED=$(grep -oE 'port\s*:\s*[0-9]+' "${PROJECT_DIR}/astro.config.mjs" 2>/dev/null \
        | grep -oE '[0-9]+' || true)
    [ -n "$DETECTED" ] && PORT="$DETECTED"
fi

# Publish URLs for portal/cert/dnsmasq + the in-runtime caddy frontdoor.
# Astro projects expose an HTTP dev server on a fixed local port — caddy
# reverse-proxies HTTPS at <project>.<zone> to it.
#
# The upstream is "localhost", not "127.0.0.1", and that is load-bearing:
# a default `astro dev` binds [::1] only, while `astro dev --host` binds
# 0.0.0.0 (IPv4 only). Either one alone leaves a literal address dialing
# a port nothing listens on, and caddy answers 502. A name lets Go's
# dialer try both families and take whichever answers, so both ways of
# starting the dev server work.
cat > "/srv/meta/${PROJECT_NAME}/urls.json" <<EOF
[
  {
    "label": "main",
    "kind": "web",
    "url": "https://${PROJECT_NAME}.${MPD_ZONE}/",
    "backend": {
      "type": "reverse-proxy",
      "upstream": "http://localhost:${PORT}"
    }
  }
]
EOF

# Effective resolved settings — read by sibling scripts (project-setup.sh,
# future Caddy generator) and by mpd for dbTag (empty for astro = no DB).
cat > "/srv/meta/${PROJECT_NAME}/effective.json" <<EOF
{
  "port": ${PORT},
  "dbTag": "",
  "dbEngine": "",
  "dbVersion": "",
  "databaseId": ""
}
EOF

echo "Done: '${PROJECT_NAME}' configured (port ${PORT})."
