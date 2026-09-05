#!/bin/bash
# project-setup.sh <project-name>
# Run by `mpd start <project>` for an mdl-demo project. Prints guidance
# only: mpd publishes the front door (configure.sh) and does not build
# or run the demo container.
set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"

# shellcheck source=/dev/null
source /opt/mpd/assets/vm/lib/source-mpd-env.sh

echo ""
echo "mpd publishes the URLs for this project but does not run it. Build and"
echo "run the demo container yourself, from the project's Makefile ON THE VM"
echo "(ssh mpd-${MPD_VM_ID} from the host):"
echo ""
echo "    cd ${PROJECT_DIR}"
echo "    make image                    # build the mdl-demo container image"
echo "    make run                      # start the test container (VM ports 6381/6382)"
echo ""
echo "then open the console — the entry point ('make run' prints its address):"
echo ""
echo "    http://<vm-bridge>:6381/          management console (IP-only)"
echo ""
echo "The console is IP-only on purpose (its Host allow-list is a security guard,"
echo "so it is not on the caddy front door). Install and open the site from the"
echo "console; the site is served at https://${PROJECT_NAME}.${MPD_ZONE}/ but you"
echo "reach it through the console, never directly."
echo ""
echo "make run removes the previous test container first; stop it with"
echo "'sudo podman stop mpd-test-mdl-demo' on the VM."
