#!/bin/bash
# project-create.sh <project-name>
# cftunnel project type — runs when `mpd create <project> --type=cftunnel`
# (or via the `*-cftunnel` suffix autodetection).
#
# A cftunnel project runs a single `cloudflared` connector with a CF
# tunnel token. The tunnel itself + its public hostname routes are
# configured on the Cloudflare side; mpd just keeps the connector
# running. One cftunnel project can fulfill many CF routes — point
# any number of public hostnames at any number of internal mpd
# projects from the CF dashboard.
#
# Per-project external exposure is opt-in on the *target* project's
# side: a moodle project must set `MPD_PHP_MOODLE_CFTUNNEL=1` for
# Caddy frontdoor to actually serve the tunnel hostname. The cftunnel
# project itself is target-agnostic.

set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"
PROJECT_ENV="${PROJECT_DIR}/mpd.env"
TEMPLATE_ENV="/opt/mpd/assets/runtimes/util/project_types/cftunnel/mpd-template.env"

if [ ! -d "$PROJECT_DIR" ]; then
    echo "Error: ${PROJECT_DIR} does not exist." >&2
    exit 1
fi

if [ ! -f "$PROJECT_ENV" ]; then
    install -m 0644 "$TEMPLATE_ENV" "$PROJECT_ENV"
    echo "Seeded ${PROJECT_ENV} from template."
else
    echo "Existing ${PROJECT_ENV} preserved."
fi

# --- Install cloudflared (idempotent) ---
# Use the absolute path; mpd invokes this script via non-interactive bash,
# which doesn't source /etc/profile.d/*, so the tool's PATH symlink may
# not be visible.
echo "Ensuring cloudflared is installed..."
bash /opt/mpd/assets/runtimes/util/project_types/cftunnel/tools/cftunnel-install

echo ""
echo "cftunnel project '${PROJECT_NAME}' scaffolded."
echo "Next:"
echo "  1. Create a Cloudflare tunnel in the CF dashboard, copy the token"
echo "  2. mpd configure ${PROJECT_NAME} MPD_CFTUNNEL_TOKEN=<token>"
echo "  3. mpd start ${PROJECT_NAME}"
echo "  4. In CF dashboard, add Public Hostname routes pointing at"
echo "     https://<projectname>.mpd.test/ for each project to expose"
echo "  5. On each exposed moodle project: mpd configure <p> MPD_PHP_MOODLE_CFTUNNEL=1"
