#!/bin/bash
# project-setup.sh <project-name>
# Sets up an Astro project that has been cloned into /srv/projects/<project-name>/:
#   - Runs nvm install (if .nvmrc present) and npm install + npm run build (as extuser)
#   - Reads port from astro.config.mjs (default 4321)
#   - Creates systemd unit mpd-<project-name>.service (runs as extuser, Restart=on-failure)
#   - Enables and starts the service
# No Apache vhost — TLS termination + reverse-proxy live in the Caddy frontdoor
# sidecar attached to the runtime pod. The sidecar reads urls.json (written by
# configure.sh with backend.upstream pointing at this project's port) and
# proxies HTTPS at <project-name>.mpd.test to 127.0.0.1:<port> via pod-shared
# netns. Per-project TLS certs at /srv/meta/<n>/cert.pem + key.pem (mpd writes them).
# Reads the runtime name from /etc/mpd/runtime (written by bootstrap.sh).
# Called by mpd create <project> / mpd start <project>.
set -euo pipefail

# shellcheck source=/dev/null
source /mnt/assets/runtime-base/lib/nvm-env.sh

RUNTIME_NAME=$(cat /etc/mpd/runtime)
PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"
SERVICE_NAME="mpd-${PROJECT_NAME}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CERT_DIR="/srv/meta/${PROJECT_NAME}"

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

cd "${PROJECT_DIR}"

# Install correct Node version if .nvmrc present (dev-owned $HOME/.nvm)
if [ -f ".nvmrc" ]; then
    nvm install
    echo "Node: $(node --version)"
fi

# Read port from astro.config.mjs (default 4321)
PORT="4321"
if [ -f "${PROJECT_DIR}/astro.config.mjs" ]; then
    DETECTED=$(grep -oE 'port\s*:\s*[0-9]+' "${PROJECT_DIR}/astro.config.mjs" 2>/dev/null \
        | grep -oE '[0-9]+' || true)
    [ -n "$DETECTED" ] && PORT="$DETECTED"
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
ExecStart=${NODE_BIN_DIR}/npm run dev -- --host 0.0.0.0 --port ${PORT} --allowed-hosts ${PROJECT_NAME}.mpd.test ${RUNTIME_NAME}.runtime.mpd.test
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
echo "Logs: mpd ${PROJECT_NAME} logs  (or: journalctl -u ${SERVICE_NAME} -f inside container)"
echo "URL:  https://${PROJECT_NAME}.mpd.test/"
