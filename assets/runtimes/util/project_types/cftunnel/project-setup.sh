#!/bin/bash
# project-setup.sh <project-name>
# cftunnel project type — runs at `mpd start <project>`.
#
# Writes/refreshes the systemd unit and the EnvironmentFile holding the
# CF tunnel token, then enables + (re)starts the unit. Idempotent: safe
# to re-run; picks up token changes from mpd.env on each invocation.

set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"
ENV_FILE="${PROJECT_DIR}/.cftunnel-env"
SERVICE_NAME="mpd-${PROJECT_NAME}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Load layered MPD_* env to get the token. Configure has already
# validated all the required values; this is a re-load before start.
# shellcheck source=/dev/null
. /mnt/assets/runtime-base/lib/source-mpd-env.sh

if [ -z "${MPD_CFTUNNEL_TOKEN:-}" ]; then
    echo "Error: MPD_CFTUNNEL_TOKEN missing — re-run mpd configure ${PROJECT_NAME}." >&2
    exit 1
fi

DEV_USER=$(id -un)

# --- Token environment file (read by systemd at service start) ---
# cloudflared honours $TUNNEL_TOKEN natively; no flag needed.
umask 077
cat > "$ENV_FILE" <<EOF
TUNNEL_TOKEN=${MPD_CFTUNNEL_TOKEN}
EOF
chmod 0600 "$ENV_FILE"

# --- Systemd unit ---
# No `--config` flag: token-based tunnels get their routing (and
# `originRequest` overrides) pushed from the CF dashboard, which
# overrides any local config file. Caddy frontdoor handles the
# tunnel hostname server-side — when a moodle project sets
# MPD_PHP_MOODLE_CFTUNNEL=1, its urls.json includes the public
# tunnel URL, so Caddy serves both internal and tunnel hostnames
# from the same vhost. cloudflared just needs to be running with
# the token; no per-tunnel host/SNI overrides needed.
sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=mpd cftunnel — ${PROJECT_NAME}
After=network-online.target
Wants=network-online.target

[Service]
User=${DEV_USER}
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_NAME}"
sudo systemctl restart "${SERVICE_NAME}"

echo ""
echo "cftunnel '${PROJECT_NAME}' service started."
echo "Logs: journalctl -u ${SERVICE_NAME} -f"
