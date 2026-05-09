#!/bin/bash
# uninstall.sh — entry shim. Forwards to lib/uninstall.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/lib/uninstall.sh" "$@"
