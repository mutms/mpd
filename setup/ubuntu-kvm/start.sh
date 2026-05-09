#!/bin/bash
# start.sh — entry shim. Forwards to lib/start.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/lib/start.sh" "$@"
