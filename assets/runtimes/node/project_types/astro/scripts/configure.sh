#!/bin/bash
# configure.sh <project-name>
# Idempotent project repair/configuration for Astro:
#   - fixes ownership of /srv/projects/<project>
#   - ensures dependencies exist
set -euo pipefail

# shellcheck source=/dev/null
source /opt/mpd/assets/runtime-base/lib/nvm-env.sh

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
# cert.pem/key.pem/project.json that Swift writes via volumeToolRun (which
# runs as the dev uid). /srv/meta is dev-owned, so plain mkdir works.
mkdir -p "/srv/meta/${PROJECT_NAME}"

# Per-project mpd.env was seeded by project-create.sh at create time;
# do not re-stage here. Layered resolution: /var/lib/mpd/env/mpd-vm.env first,
# then per-project mpd.env.
# shellcheck source=/dev/null
source /opt/mpd/assets/runtime-base/lib/source-mpd-env.sh

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

# Resolve dev-server port: per-project mpd.env override → astro.config.mjs → 4321.
if [ -n "${MPD_NODE_ASTRO_PORT:-}" ]; then
    PORT="${MPD_NODE_ASTRO_PORT}"
else
    PORT="4321"
    if [ -f "${PROJECT_DIR}/astro.config.mjs" ]; then
        DETECTED=$(grep -oE 'port\s*:\s*[0-9]+' "${PROJECT_DIR}/astro.config.mjs" 2>/dev/null \
            | grep -oE '[0-9]+' || true)
        [ -n "$DETECTED" ] && PORT="$DETECTED"
    fi
fi

# Publish URLs for portal/TUI/cert/dnsmasq + Phase 8 frontdoor sidecar.
# Astro projects expose an HTTP dev server on a fixed local port — the
# (future) Caddy frontdoor reverse-proxies HTTPS at <project>.mpd.test to it.
cat > "/srv/meta/${PROJECT_NAME}/urls.json" <<EOF
[
  {
    "label": "main",
    "kind": "web",
    "url": "https://${PROJECT_NAME}.mpd.test/",
    "backend": {
      "type": "reverse-proxy",
      "upstream": "http://127.0.0.1:${PORT}"
    }
  }
]
EOF

# Effective resolved settings — read by sibling scripts (project-setup.sh,
# future Caddy generator) and by Swift for dbTag (empty for astro = no DB).
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
