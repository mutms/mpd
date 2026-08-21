#!/bin/bash
# project-setup.sh <project-name>
# Run by `mpd start <project>` for an mdl-demo project.
#
# Prints. That is the whole job.
#
# An mdl-demo project is the source tree of the mdl-demo tool. mpd publishes
# the front door (configure.sh: caddy vhosts, certificate, DNS for the
# console and the site) and stops there: it does not build or run the demo
# container. The developer does that from the project's Makefile — on the
# VM, where podman is.
set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"

# shellcheck source=/dev/null
source /opt/mpd/assets/runtime/lib/source-mpd-env.sh

echo ""
echo "mpd publishes the URLs for this project but does not run it. Build and"
echo "run the demo container yourself, from the project's Makefile ON THE VM"
echo "(ssh mpd-${MPD_VM_ID}-vm from the host; podman is not in the runtime):"
echo ""
echo "    cd ${PROJECT_DIR}"
echo "    make image                    # build the mdl-demo container image"
echo "    make run                      # start the test container (VM ports 6381/6382)"
echo ""
echo "then open:"
echo ""
echo "    https://${PROJECT_NAME}.${MPD_ZONE}/          management console"
echo "    https://site.${PROJECT_NAME}.${MPD_ZONE}/     the demo site, once installed"
echo ""
echo "make run removes the previous test container first; stop it with"
echo "'sudo podman stop mpd-test-mdl-demo' on the VM."
