#!/bin/bash
# project-setup.sh <project-name>
# Run by `mpd start <project>` for an mdl-demo project.
#
# Prints. That is the whole job.
#
# An mdl-demo project is the source tree of the mdl-demo tool. mpd tracks
# it and stops there: it does not build or run the demo container. The
# developer does that by hand, from the project's own Makefile.
set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"

echo ""
echo "mpd tracks this project but does not run it. Build and run the demo"
echo "container yourself, from the project's own Makefile:"
echo ""
echo "    cd ${PROJECT_DIR}"
echo "    make image                    # build the mdl-demo container"
echo "    make run                      # run it (web UI on 127.0.0.1:8081)"
echo ""
echo "Stop and remove it with the container commands in the project README."
