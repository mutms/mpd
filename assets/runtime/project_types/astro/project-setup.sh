#!/bin/bash
# project-setup.sh <project-name>
# Sets up an Astro project that has been cloned into /srv/projects/<project-name>/:
#   - Runs nvm install (if .nvmrc present) and npm install + npm run build (as extuser)
#   - Reads the dev-server port from /srv/meta/<n>/effective.json (written by
#     scripts/configure.sh, which is also what urls.json points caddy at)
#   - Creates systemd unit mpd-<project-name>.service (runs as extuser, Restart=on-failure)
#   - Enables and starts the service
# No Apache vhost — TLS termination + reverse-proxy live in the in-runtime
# caddy frontdoor (mpd-caddy.service). It reads urls.json (written by
# configure.sh with backend.upstream pointing at this project's port) and
# proxies HTTPS at <project-name>.<zone> to 127.0.0.1:<port> on localhost. Per-project TLS certs at /srv/meta/<n>/cert.pem + key.pem (mpd writes them).
# Reads the runtime name from /etc/mpd/runtime (written by bootstrap.sh).
# Called by mpd create <project> / mpd start <project>.
set -euo pipefail

# shellcheck source=/dev/null
source /opt/mpd/assets/runtime/lib/nvm-env.sh

RUNTIME_NAME=$(cat /etc/mpd/runtime)
PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"
SERVICE_NAME="mpd-${PROJECT_NAME}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CERT_DIR="/srv/meta/${PROJECT_NAME}"
EFFECTIVE_FILE="/srv/meta/${PROJECT_NAME}/effective.json"

# Verify the project directory exists with package.json
if [ ! -d "$PROJECT_DIR" ]; then
    echo "Error: ${PROJECT_DIR} does not exist — clone the project first" >&2
    exit 1
fi
if [ ! -f "${PROJECT_DIR}/package.json" ]; then
    echo "Error: ${PROJECT_DIR}/package.json not found — is this an Astro/Node project?" >&2
    exit 1
fi

# Verify per-project TLS cert exists
if [ ! -f "${CERT_DIR}/cert.pem" ] || [ ! -f "${CERT_DIR}/key.pem" ]; then
    echo "Error: TLS cert not found at ${CERT_DIR}/cert.pem — run mpd to generate it first" >&2
    exit 1
fi

if [ ! -f "$EFFECTIVE_FILE" ]; then
    echo "Error: ${EFFECTIVE_FILE} missing — run mpd configure ${PROJECT_NAME} first" >&2
    exit 1
fi

# --- Resolve effective settings (configure.sh wrote effective.json) ---
# Also exports MPD_ZONE, which the unit's --allowed-hosts needs: caddy
# reverse-proxies with the original Host header, and Astro's dev server
# rejects any Host it wasn't told about.
# shellcheck source=/dev/null
source /opt/mpd/assets/runtime/lib/source-mpd-env.sh

# Port must match what configure.sh published as caddy's upstream in
# urls.json — read the same file rather than re-deriving it, or a
# MPD_NODE_ASTRO_PORT override would leave caddy proxying to nothing.
PORT=$(jq -r '.port // empty' "$EFFECTIVE_FILE")
if [ -z "$PORT" ]; then
    echo "Error: port not set in ${EFFECTIVE_FILE}" >&2
    exit 1
fi

cd "${PROJECT_DIR}"

# Install correct Node version if .nvmrc present (dev-owned $HOME/.nvm)
if [ -f ".nvmrc" ]; then
    nvm install
    echo "Node: $(node --version)"
fi

# Install dependencies and build. Script runs as the dev user
# (projectExec --user <dev>); plain invocations land with correct ownership.
echo "Running npm install..."
npm install

echo "Running npm run build..."
npm run build

# Capture node bin directory while nvm is loaded — systemd environment is minimal
NODE_BIN_DIR="$(dirname "$(which node)")"

# Create systemd unit for this project (runs as the dev user)
DEV_USER=$(id -un)
sudo tee "${SERVICE_FILE}" > /dev/null << EOF
[Unit]
Description=Astro Dev Server (${PROJECT_NAME})
After=network.target

[Service]
User=${DEV_USER}
WorkingDirectory=${PROJECT_DIR}
Environment=PATH=${NODE_BIN_DIR}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${NODE_BIN_DIR}/npm run dev -- --host 0.0.0.0 --port ${PORT} --allowed-hosts ${PROJECT_NAME}.${MPD_ZONE},runtime.${MPD_ZONE},${RUNTIME_NAME}.runtime.${MPD_ZONE}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_NAME}"
sudo systemctl restart "${SERVICE_NAME}"

echo ""
echo "Dev server started for '${PROJECT_NAME}' on port ${PORT}"
echo "Logs: journalctl -u ${SERVICE_NAME} -f   (inside the runtime)"
echo "URL:  https://${PROJECT_NAME}.${MPD_ZONE}/"
