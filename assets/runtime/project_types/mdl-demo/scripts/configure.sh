#!/bin/bash
# configure.sh <project-name>
# Idempotent configure step for an mdl-demo project, run by `mpd start`.
#
# An mdl-demo project is the source tree of the mdl-demo tool itself. mpd
# does not build or run its demo container — the developer does that on the
# VM with `make image && make run` (podman lives on the VM, not in the
# runtime). What mpd contributes is the front door: the test container
# publishes its console on VM port 6381 and the Moodle site on 6382 (the
# contract with mdl-demo's Makefile), and the two URLs below make the
# runtime caddy serve them as https://<project>.<zone> and
# https://site.<project>.<zone> — vhost, certificate SANs and DNS all follow
# from urls.json, exactly as for any other project.
#
# The upstream is the VM's bridge address (the runtime reaches the VM there;
# 127.0.0.1 would be the runtime itself), read from the same vm.json that
# provides MPD_ZONE.
#
#   urls.json       console + site, reverse-proxied to the VM's 6381/6382.
#   effective.json  empty database fields — this type uses no database.
#                   Its presence is what marks the project "configured".
set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"
TYPE_DIR="/opt/mpd/assets/runtime/project_types/mdl-demo"
CONSOLE_PORT=6381
SITE_PORT=6382

if [ ! -d "$PROJECT_DIR" ]; then
    echo "Error: ${PROJECT_DIR} does not exist — run mpd init ${PROJECT_NAME} first" >&2
    exit 1
fi

# Provides MPD_ZONE (and fails loudly without it).
# shellcheck source=/dev/null
source /opt/mpd/assets/runtime/lib/source-mpd-env.sh

GATEWAY=$(jq -r '.gateway // empty' /srv/meta/vm.json 2>/dev/null || true)
if [ -z "$GATEWAY" ]; then
    echo "Error: VM gateway unavailable (/srv/meta/vm.json) — run 'mpd --start' on the VM to republish it" >&2
    exit 1
fi

# Re-apply template/ so a project created before a template file existed
# picks it up here. mpd.env is never overwritten once present.
# shellcheck source=/dev/null
. /opt/mpd/assets/runtime/lib/project-template.sh
apply_project_template "$PROJECT_NAME" "$TYPE_DIR"

# /srv/meta is dev-owned, so a plain mkdir works.
mkdir -p "/srv/meta/${PROJECT_NAME}"

cat > "/srv/meta/${PROJECT_NAME}/urls.json" <<EOF
[
  {
    "label": "console",
    "kind": "web",
    "url": "https://${PROJECT_NAME}.${MPD_ZONE}/",
    "backend": {
      "type": "reverse-proxy",
      "upstream": "http://${GATEWAY}:${CONSOLE_PORT}"
    }
  },
  {
    "label": "site",
    "kind": "web",
    "url": "https://site.${PROJECT_NAME}.${MPD_ZONE}/",
    "backend": {
      "type": "reverse-proxy",
      "upstream": "http://${GATEWAY}:${SITE_PORT}"
    }
  }
]
EOF

# No database: this type uses none. An empty dbTag keeps mpd from
# provisioning one. The keys match what mpd reads from effective.json; the
# ports are informational (project-setup.sh prints them).
cat > "/srv/meta/${PROJECT_NAME}/effective.json" <<EOF
{
  "dbTag": "",
  "dbEngine": "",
  "dbVersion": "",
  "databaseId": "",
  "consolePort": ${CONSOLE_PORT},
  "sitePort": ${SITE_PORT}
}
EOF

echo "Done: '${PROJECT_NAME}' configured (mdl-demo — https://${PROJECT_NAME}.${MPD_ZONE}/ → VM :${CONSOLE_PORT}, https://site.${PROJECT_NAME}.${MPD_ZONE}/ → VM :${SITE_PORT})."
