#!/bin/bash
# stop.sh — entry shim. Forwards to lib/stop.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/lib/stop.sh" "$@"
