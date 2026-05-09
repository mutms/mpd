#!/bin/bash
# setup.sh — entry shim. Forwards to lib/setup.sh.
# Run: bash setup.sh   (from the ubuntu-kvm/ directory or via absolute path)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/lib/setup.sh" "$@"
