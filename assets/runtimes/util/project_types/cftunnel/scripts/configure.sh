#!/bin/bash
# configure.sh <project-name>
# cftunnel project type — runs at `mpd configure <project>`.
#
# Validates that a CF tunnel token is set, writes minimal meta files.
# The cftunnel project doesn't expose any URLs of its own (CF
# dashboard owns route configuration); urls.json stays empty so the
# project shows up cleanly in `mpd list` without phantom URLs.

set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"
META_DIR="/srv/meta/${PROJECT_NAME}"

# Load layered MPD_* env. Per-project mpd.env wins.
# shellcheck source=/dev/null
. /mnt/assets/runtime-base/lib/source-mpd-env.sh

if [ -z "${MPD_CFTUNNEL_TOKEN:-}" ]; then
    echo "Error: MPD_CFTUNNEL_TOKEN is not set." >&2
    echo "       Set it via: mpd configure ${PROJECT_NAME} MPD_CFTUNNEL_TOKEN=<token>" >&2
    echo "       Tokens are issued by the Cloudflare dashboard when you create a tunnel." >&2
    exit 1
fi

# --- Write minimal meta files ---
mkdir -p "$META_DIR"
cat > "${META_DIR}/effective.json" <<EOF
{
  "dbTag": "",
  "dbEngine": "",
  "dbVersion": "",
  "databaseId": ""
}
EOF
cat > "${META_DIR}/urls.json" <<EOF
[]
EOF

echo "Done: cftunnel '${PROJECT_NAME}' configured."
