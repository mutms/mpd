#!/bin/bash
# project-stop.sh <project-name>
# Run by `mpd stop <project>` for an Astro project.
#
# Prints. That is the whole job — see project-setup.sh for why nothing
# here may run a command inside the project.
#
# `mpd stop` records the project as stopped. The vhost, certificate and
# DNS record stay, because those are `mpd configure`'s — so the URL keeps
# resolving and answers again as soon as a server is up.
set -euo pipefail

PROJECT_NAME="$1"
PROJECT_DIR="/srv/projects/${PROJECT_NAME}"

echo ""
echo "mpd does not run Astro's server, so there is nothing here for it to stop."
echo "If one is running, stop it with Astro's own command:"
echo ""
echo "    cd ${PROJECT_DIR}"
echo "    npx astro dev stop            # or: npx astro preview stop"
echo ""
echo "One started in the foreground stops with Ctrl-C."
