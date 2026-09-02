#!/bin/bash
# Hook: install the PhpStorm backend from a seeded installer tarball if present.
set -euo pipefail

exec /opt/mpd/assets/vm/bin/phpstorm-install-app
